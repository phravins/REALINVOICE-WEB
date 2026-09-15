defmodule RealinvoiceCloudWeb.SyncIngestControllerTest do
  use RealinvoiceCloudWeb.ConnCase, async: true

  import Ecto.Query

  import RealinvoiceCloud.NodesFixtures

  alias RealinvoiceCloud.Billing
  alias RealinvoiceCloud.Nodes
  alias RealinvoiceCloud.Repo

  setup %{conn: conn} do
    {node, token} = node_with_token(%{name: "POS-07"})

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)

    %{conn: conn, node: node, token: token}
  end

  defp ingest(conn, batch), do: post(conn, ~p"/api/sync/ingest", batch)

  defp customer_row(client_id, overrides \\ %{}) do
    %{
      "client_id" => client_id,
      "type" => "customer",
      "data" =>
        Map.merge(
          %{"name" => "Thiruvalluvar Networks", "place_of_supply" => "Tamil Nadu"},
          overrides
        )
    }
  end

  defp item_row(client_id, overrides \\ %{}) do
    %{
      "client_id" => client_id,
      "type" => "item",
      "data" =>
        Map.merge(
          %{
            "item_code" => "SW-CORE-48P",
            "description" => "48-port Core Switch",
            "rate" => "96000.00",
            "tax_rate" => "18.00",
            "uom" => "Nos"
          },
          overrides
        )
    }
  end

  defp invoice_row(client_id, overrides \\ %{}) do
    %{
      "client_id" => client_id,
      "type" => "invoice",
      "data" =>
        Map.merge(
          %{
            "invoice_no" => "RI-2026-0001",
            "date" => "2026-09-13",
            "subtotal" => "96000.00",
            "cgst" => "8640.00",
            "sgst" => "8640.00",
            "igst" => "0.00",
            "grand_total" => "113280.00",
            "payment_type" => "Credit",
            "created_by" => "Meena S (till-1)"
          },
          overrides
        )
    }
  end

  defp line_data(overrides \\ %{}) do
    Map.merge(
      %{"qty" => "1", "rate" => "96000.00", "tax_rate" => "18.00", "line_total" => "96000.00"},
      overrides
    )
  end

  defp full_batch do
    %{
      "rows" => [
        customer_row("cust-1"),
        item_row("item-1"),
        invoice_row("inv-1", %{"customer_client_id" => "cust-1"}),
        %{
          "client_id" => "line-1",
          "type" => "invoice_line",
          "invoice_client_id" => "inv-1",
          "data" => line_data(%{"item_client_id" => "item-1"})
        }
      ]
    }
  end

  defp results_by_client_id(conn) do
    conn |> json_response(200) |> Map.fetch!("results") |> Map.new(&{&1["client_id"], &1})
  end

  describe "authentication" do
    test "rejects a request with no token", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> post(~p"/api/sync/ingest", full_batch())

      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "rejects an empty bearer token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer   ")
        |> post(~p"/api/sync/ingest", full_batch())

      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "rejects a made-up token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer rin_totally-made-up-token")
        |> post(~p"/api/sync/ingest", full_batch())

      assert json_response(conn, 401)["error"] == "unauthorized"
      assert Repo.aggregate(Billing.Invoice, :count) == 0
    end

    test "rejects any non-empty token that is not an issued one", %{conn: conn} do
      # The behaviour this stage removed: garbage used to be accepted.
      for garbage <- ["x", "hunter2", "Bearer", "rin_", String.duplicate("a", 64)] do
        conn =
          conn
          |> put_req_header("authorization", "Bearer " <> garbage)
          |> post(~p"/api/sync/ingest", full_batch())

        assert json_response(conn, 401)["error"] == "unauthorized"
      end

      assert Repo.aggregate(Billing.Invoice, :count) == 0
    end

    test "rejects a token belonging to a revoked node", %{conn: conn} do
      {_node, token} = revoked_node_with_token(%{name: "POS-GONE"})

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> post(~p"/api/sync/ingest", full_batch())

      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "a node revoked between requests is rejected on its very next one", %{
      conn: conn,
      node: node
    } do
      assert json_response(ingest(conn, full_batch()), 200)

      {:ok, _node} = Nodes.revoke_node(node)

      retry = post(conn, ~p"/api/sync/ingest", full_batch())
      assert json_response(retry, 401)["error"] == "unauthorized"
    end

    test "a reinstated node works again with the token it already had", %{conn: conn, node: node} do
      {:ok, node} = Nodes.revoke_node(node)
      assert json_response(post(conn, ~p"/api/sync/ingest", full_batch()), 401)

      {:ok, _node} = Nodes.reinstate_node(node)
      assert json_response(post(conn, ~p"/api/sync/ingest", full_batch()), 200)
    end

    test "accepts the token in x-api-token as well", %{conn: conn, token: token} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> put_req_header("x-api-token", token)
        |> post(~p"/api/sync/ingest", full_batch())

      assert json_response(conn, 200)["batch"]["accepted"] == 4
    end

    test "does not say why a token failed", %{conn: conn} do
      {_node, revoked_token} = revoked_node_with_token(%{name: "POS-GONE"})

      unknown =
        conn
        |> put_req_header("authorization", "Bearer rin_unknown")
        |> post(~p"/api/sync/ingest", full_batch())
        |> json_response(401)

      revoked =
        conn
        |> put_req_header("authorization", "Bearer " <> revoked_token)
        |> post(~p"/api/sync/ingest", full_batch())
        |> json_response(401)

      # Distinguishing "unknown" from "revoked" would hand a caller a probe.
      assert unknown == revoked
    end
  end

  describe "last_seen_at" do
    test "is set on the first successful request", %{conn: conn, node: node} do
      assert is_nil(node.last_seen_at)

      ingest(conn, full_batch())

      assert %DateTime{} = Nodes.get_node!(node.id).last_seen_at
    end

    test "moves on each successful request", %{conn: conn, node: node} do
      ingest(conn, full_batch())
      first = Nodes.get_node!(node.id).last_seen_at

      # Rewind so a second request within the same second still shows a change.
      Nodes.get_node!(node.id)
      |> Ecto.Changeset.change(last_seen_at: DateTime.add(first, -60, :second))
      |> Repo.update!()

      ingest(conn, full_batch())

      assert DateTime.compare(Nodes.get_node!(node.id).last_seen_at, first) in [:eq, :gt]
    end

    test "is not touched by a rejected token", %{conn: conn} do
      {node, _token} = revoked_node_with_token(%{name: "POS-GONE"})

      conn
      |> put_req_header("authorization", "Bearer rin_nope")
      |> post(~p"/api/sync/ingest", full_batch())

      assert is_nil(Nodes.get_node!(node.id).last_seen_at)
    end
  end

  describe "a malformed batch" do
    test "an empty batch is accepted and does nothing", %{conn: conn} do
      conn = ingest(conn, %{"rows" => []})

      assert json_response(conn, 200)["batch"]["received"] == 0
    end

    test "is rejected when rows is not a list", %{conn: conn} do
      conn = ingest(conn, %{"rows" => %{"nope" => true}})

      assert json_response(conn, 422)["detail"] =~ "rows must be a list"
    end

    test "is rejected when it carries too many rows", %{conn: conn} do
      rows = for n <- 1..1001, do: customer_row("cust-#{n}")
      conn = ingest(conn, %{"rows" => rows})

      assert json_response(conn, 422)["detail"] =~ "at most 1000 rows"
    end
  end

  describe "a good batch" do
    test "accepts every row and reports what it did with each", %{conn: conn} do
      conn = ingest(conn, full_batch())
      body = json_response(conn, 200)

      assert body["batch"] == %{
               "store_node_id" => "POS-07",
               "received" => 4,
               "accepted" => 4,
               "rejected" => 0
             }

      results = Map.new(body["results"], &{&1["client_id"], &1})

      for client_id <- ~w(cust-1 item-1 inv-1 line-1) do
        assert results[client_id]["status"] == "accepted"
        assert results[client_id]["action"] == "inserted"
        assert is_integer(results[client_id]["id"])
      end

      assert results["inv-1"]["type"] == "invoice"
      assert results["line-1"]["type"] == "invoice_line"
    end

    test "stores the invoice with its customer, its line and its item", %{conn: conn, node: node} do
      ingest(conn, full_batch())

      invoice =
        Billing.get_by_client_id(:invoice, node.id, "inv-1") |> then(&Billing.get_invoice!(&1.id))

      assert invoice.invoice_no == "RI-2026-0001"
      assert invoice.store_node_id == "POS-07"
      assert invoice.created_by == "Meena S (till-1)"
      assert Decimal.equal?(invoice.grand_total, Decimal.new("113280.00"))
      assert invoice.customer.name == "Thiruvalluvar Networks"
      assert [line] = invoice.lines
      assert line.client_id == "line-1"
      assert line.item.item_code == "SW-CORE-48P"
      assert Decimal.equal?(line.line_total, Decimal.new("96000.00"))
    end

    test "accepts lines nested inside the invoice instead of as their own rows", %{
      conn: conn,
      node: node
    } do
      batch = %{
        "rows" => [
          item_row("item-1"),
          invoice_row("inv-1", %{
            "lines" => [line_data(%{"item_client_id" => "item-1", "client_id" => "nested-1"})]
          })
        ]
      }

      conn = ingest(conn, batch)
      assert json_response(conn, 200)["batch"]["rejected"] == 0

      invoice =
        Billing.get_by_client_id(:invoice, node.id, "inv-1") |> then(&Billing.get_invoice!(&1.id))

      assert [%{client_id: "nested-1"}] = invoice.lines
    end

    test "does not need the rows in dependency order", %{conn: conn, node: node} do
      batch = full_batch() |> Map.update!("rows", &Enum.reverse/1)

      conn = ingest(conn, batch)

      assert json_response(conn, 200)["batch"]["accepted"] == 4
      assert Billing.get_by_client_id(:invoice, node.id, "inv-1")
    end

    test "files every row under the authenticated node", %{conn: conn, node: node} do
      ingest(conn, full_batch())

      invoice = Billing.get_by_client_id(:invoice, node.id, "inv-1")
      assert invoice.store_node_id == "POS-07"
      assert invoice.node_id == node.id
      assert Billing.get_by_client_id(:customer, node.id, "cust-1").node_id == node.id
      assert Billing.get_by_client_id(:item, node.id, "item-1").node_id == node.id
      assert Billing.get_by_client_id(:invoice_line, node.id, "line-1").node_id == node.id
    end
  end

  describe "idempotency" do
    test "re-sending an identical batch inserts nothing new", %{conn: conn} do
      first = ingest(conn, full_batch())
      assert json_response(first, 200)["batch"]["accepted"] == 4

      second = ingest(conn, full_batch())
      body = json_response(second, 200)

      assert body["batch"]["accepted"] == 4
      assert body["batch"]["rejected"] == 0

      assert Repo.aggregate(Billing.Invoice, :count) == 1
      assert Repo.aggregate(Billing.InvoiceLine, :count) == 1
      assert Repo.aggregate(Billing.Customer, :count) == 1
      assert Repo.aggregate(Billing.Item, :count) == 1
    end

    test "reports the retried rows as unchanged or updated, never inserted again", %{conn: conn} do
      ingest(conn, full_batch())
      results = conn |> ingest(full_batch()) |> results_by_client_id()

      assert results["inv-1"]["action"] == "unchanged"
      assert results["line-1"]["action"] == "unchanged"
      # Customers and items are upserted, so a retry rewrites them in place.
      assert results["cust-1"]["action"] == "updated"
      assert results["item-1"]["action"] == "updated"
    end

    test "returns the same record ids on the retry", %{conn: conn} do
      first = conn |> ingest(full_batch()) |> results_by_client_id()
      second = conn |> ingest(full_batch()) |> results_by_client_id()

      for client_id <- ~w(cust-1 item-1 inv-1 line-1) do
        assert first[client_id]["id"] == second[client_id]["id"]
      end
    end

    test "a line retried after its invoice landed in an earlier batch is a no-op", %{conn: conn} do
      ingest(conn, full_batch())

      # The worker retries only the line, its invoice having been acknowledged.
      line_only = %{
        "rows" => [
          %{
            "client_id" => "line-1",
            "type" => "invoice_line",
            "invoice_client_id" => "inv-1",
            "data" => line_data(%{"item_client_id" => "item-1"})
          }
        ]
      }

      results = conn |> ingest(line_only) |> results_by_client_id()

      assert results["line-1"]["status"] == "accepted"
      assert results["line-1"]["action"] == "unchanged"
      assert Repo.aggregate(Billing.InvoiceLine, :count) == 1
    end
  end

  describe "invoices are append-only" do
    test "a re-sent invoice is never rewritten, even with different figures", %{
      conn: conn,
      node: node
    } do
      ingest(conn, full_batch())

      amended =
        full_batch()
        |> Map.update!("rows", fn rows ->
          Enum.map(rows, fn
            %{"client_id" => "inv-1"} = row ->
              put_in(row, ["data", "grand_total"], "1.00")

            row ->
              row
          end)
        end)

      results = conn |> ingest(amended) |> results_by_client_id()

      assert results["inv-1"]["action"] == "unchanged"

      invoice = Billing.get_by_client_id(:invoice, node.id, "inv-1")
      assert Decimal.equal?(invoice.grand_total, Decimal.new("113280.00"))
    end

    test "a different invoice reusing a number on the same desk is rejected", %{conn: conn} do
      ingest(conn, full_batch())

      clash = %{
        "rows" => [
          item_row("item-2", %{"item_code" => "OTHER"}),
          invoice_row("inv-2", %{
            "lines" => [line_data(%{"item_client_id" => "item-2"})]
          })
        ]
      }

      results = conn |> ingest(clash) |> results_by_client_id()

      assert results["inv-2"]["status"] == "rejected"

      assert results["inv-2"]["errors"]["store_node_id"] == [
               "already exists for this billing desk"
             ]
    end

    test "the same invoice number on a different desk is fine", %{conn: conn} do
      ingest(conn, full_batch())

      {_other_node, other_token} = node_with_token(%{name: "POS-08"})

      other_conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> other_token)

      assert json_response(ingest(other_conn, full_batch()), 200)["batch"]["rejected"] == 0
      assert Repo.aggregate(Billing.Invoice, :count) == 2
    end
  end

  describe "client ids are scoped to the node" do
    test "two desks may use the same client ids without colliding", %{conn: conn} do
      {_other_node, other_token} = node_with_token(%{name: "POS-08"})

      other_conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> other_token)

      # Byte-for-byte the same batch, from two different desks. Under a global
      # unique index on client_id the second desk's rows would be rejected as
      # duplicates of the first's.
      assert json_response(ingest(conn, full_batch()), 200)["batch"]["rejected"] == 0
      assert json_response(ingest(other_conn, full_batch()), 200)["batch"]["rejected"] == 0

      assert Repo.aggregate(Billing.Invoice, :count) == 2
      assert Repo.aggregate(Billing.Customer, :count) == 2
      assert Repo.aggregate(Billing.Item, :count) == 2
      assert Repo.aggregate(Billing.InvoiceLine, :count) == 2
    end

    test "each desk's rows stay distinct records", %{conn: conn, node: node} do
      {other_node, other_token} = node_with_token(%{name: "POS-08"})

      other_conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> other_token)

      ingest(conn, full_batch())
      ingest(other_conn, full_batch())

      mine = Billing.get_by_client_id(:invoice, node.id, "inv-1")
      theirs = Billing.get_by_client_id(:invoice, other_node.id, "inv-1")

      refute mine.id == theirs.id
      assert mine.store_node_id == "POS-07"
      assert theirs.store_node_id == "POS-08"
    end

    test "one desk's retry never resolves to another desk's record", %{conn: conn} do
      {other_node, other_token} = node_with_token(%{name: "POS-08"})

      other_conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> other_token)

      ingest(conn, full_batch())
      results = other_conn |> ingest(full_batch()) |> results_by_client_id()

      # POS-08 has never sent these ids before, so they are inserts, not
      # matches against POS-07's rows.
      assert results["inv-1"]["action"] == "inserted"

      assert results["inv-1"]["id"] ==
               Billing.get_by_client_id(:invoice, other_node.id, "inv-1").id
    end
  end

  describe "per-row rejection" do
    test "one bad row does not take the good ones down with it", %{conn: conn, node: node} do
      batch = %{
        "rows" => [
          customer_row("cust-1"),
          # A negative rate fails the stage 2 item changeset.
          item_row("item-bad", %{"rate" => "-5.00"}),
          item_row("item-1"),
          invoice_row("inv-1", %{
            "lines" => [line_data(%{"item_client_id" => "item-1"})]
          })
        ]
      }

      conn = ingest(conn, batch)
      body = json_response(conn, 200)

      assert body["batch"] == %{
               "store_node_id" => "POS-07",
               "received" => 4,
               "accepted" => 3,
               "rejected" => 1
             }

      results = Map.new(body["results"], &{&1["client_id"], &1})

      assert results["item-bad"]["status"] == "rejected"
      assert results["item-bad"]["errors"]["rate"] == ["must be greater than or equal to 0"]
      assert results["cust-1"]["status"] == "accepted"
      assert results["inv-1"]["status"] == "accepted"

      assert Billing.get_by_client_id(:invoice, node.id, "inv-1")
      refute Billing.get_by_client_id(:item, node.id, "item-bad")
    end

    test "an invalid invoice takes its own lines with it and nothing else", %{conn: conn} do
      batch = %{
        "rows" => [
          customer_row("cust-1"),
          item_row("item-1"),
          # Zero quantity fails the stage 2 invoice line changeset.
          invoice_row("inv-1"),
          %{
            "client_id" => "line-1",
            "type" => "invoice_line",
            "invoice_client_id" => "inv-1",
            "data" => line_data(%{"item_client_id" => "item-1", "qty" => "0"})
          }
        ]
      }

      results = conn |> ingest(batch) |> results_by_client_id()

      assert results["inv-1"]["status"] == "rejected"
      assert results["line-1"]["status"] == "rejected"
      assert results["line-1"]["errors"]["base"] == ["its invoice was rejected"]
      assert results["cust-1"]["status"] == "accepted"

      assert Repo.aggregate(Billing.Invoice, :count) == 0
      assert Repo.aggregate(Billing.InvoiceLine, :count) == 0
      assert Repo.aggregate(Billing.Customer, :count) == 1
    end

    test "rejects a row with no client_id", %{conn: conn} do
      batch = %{
        "rows" => [%{"type" => "customer", "data" => %{"name" => "X"}}]
      }

      assert [result] = json_response(ingest(conn, batch), 200)["results"]
      assert result["status"] == "rejected"
      assert result["errors"]["base"] == ["client_id is required"]
    end

    test "rejects an unknown row type", %{conn: conn} do
      batch = %{
        "rows" => [%{"client_id" => "x-1", "type" => "spaceship", "data" => %{}}]
      }

      assert [result] = json_response(ingest(conn, batch), 200)["results"]
      assert result["status"] == "rejected"
      assert hd(result["errors"]["base"]) =~ "type must be one of"
    end

    test "rejects a row whose data is not an object", %{conn: conn} do
      batch = %{
        "rows" => [%{"client_id" => "x-1", "type" => "customer", "data" => "nope"}]
      }

      assert [result] = json_response(ingest(conn, batch), 200)["results"]
      assert result["errors"]["base"] == ["data must be an object"]
    end

    test "rejects a line with no invoice to attach to", %{conn: conn} do
      batch = %{
        "rows" => [
          %{
            "client_id" => "line-orphan",
            "type" => "invoice_line",
            "invoice_client_id" => "inv-does-not-exist",
            "data" => line_data()
          }
        ]
      }

      assert [result] = json_response(ingest(conn, batch), 200)["results"]
      assert result["status"] == "rejected"
      assert hd(result["errors"]["base"]) =~ "no invoice in this batch or already stored"
    end

    test "rejects a line that names no invoice at all", %{conn: conn} do
      batch = %{
        "rows" => [%{"client_id" => "line-1", "type" => "invoice_line", "data" => line_data()}]
      }

      assert [result] = json_response(ingest(conn, batch), 200)["results"]
      assert result["errors"]["base"] == ["invoice_client_id is required for an invoice_line row"]
    end
  end

  describe "what a desk is not allowed to decide" do
    test "the envelope's store_node_id overrides whatever a row claims", %{conn: conn, node: node} do
      batch = %{
        "rows" => [customer_row("cust-1", %{"store_node_id" => "POS-99"})]
      }

      ingest(conn, batch)

      assert Billing.get_by_client_id(:customer, node.id, "cust-1").store_node_id == "POS-07"
    end

    test "a raw customer_id in the payload is ignored", %{conn: conn, node: node} do
      other = Billing.create_customer!(%{name: "Someone Else", store_node_id: "POS-99"})

      batch = %{
        "rows" => [
          item_row("item-1"),
          invoice_row("inv-1", %{
            "customer_id" => other.id,
            "lines" => [line_data(%{"item_client_id" => "item-1"})]
          })
        ]
      }

      ingest(conn, batch)

      assert is_nil(Billing.get_by_client_id(:invoice, node.id, "inv-1").customer_id)
    end

    test "an invoice naming an unknown customer_client_id is stored as a counter sale", %{
      conn: conn,
      node: node
    } do
      batch = %{
        "rows" => [
          item_row("item-1"),
          invoice_row("inv-1", %{
            "customer_client_id" => "never-synced",
            "lines" => [line_data(%{"item_client_id" => "item-1"})]
          })
        ]
      }

      assert json_response(ingest(conn, batch), 200)["batch"]["rejected"] == 0
      assert is_nil(Billing.get_by_client_id(:invoice, node.id, "inv-1").customer_id)
    end
  end

  describe "upserts" do
    test "a customer re-sent with new details is updated in place", %{conn: conn, node: node} do
      ingest(conn, %{"store_node_id" => "POS-07", "rows" => [customer_row("cust-1")]})

      ingest(conn, %{
        "rows" => [customer_row("cust-1", %{"name" => "Thiruvalluvar Networks Pvt Ltd"})]
      })

      assert Repo.aggregate(Billing.Customer, :count) == 1

      assert Billing.get_by_client_id(:customer, node.id, "cust-1").name ==
               "Thiruvalluvar Networks Pvt Ltd"
    end

    test "an item re-sent with a new price is updated in place", %{conn: conn, node: node} do
      ingest(conn, %{"store_node_id" => "POS-07", "rows" => [item_row("item-1")]})

      ingest(conn, %{
        "rows" => [item_row("item-1", %{"rate" => "99000.00"})]
      })

      assert Repo.aggregate(Billing.Item, :count) == 1

      assert Decimal.equal?(
               Billing.get_by_client_id(:item, node.id, "item-1").rate,
               Decimal.new("99000.00")
             )
    end

    test "repricing an item does not change an invoice already issued at the old price", %{
      conn: conn
    } do
      ingest(conn, full_batch())

      ingest(conn, %{
        "rows" => [item_row("item-1", %{"rate" => "1.00"})]
      })

      line = Repo.one(from l in Billing.InvoiceLine, where: l.client_id == "line-1")
      assert Decimal.equal?(line.rate, Decimal.new("96000.00"))
    end
  end
end
