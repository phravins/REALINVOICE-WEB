defmodule RealinvoiceCloudWeb.SyncIngestControllerTest do
  use RealinvoiceCloudWeb.ConnCase, async: true

  import Ecto.Query

  alias RealinvoiceCloud.Billing
  alias RealinvoiceCloud.Repo
  alias RealinvoiceCloud.Sync

  @token "desk-token-abc"

  setup %{conn: conn} do
    %{conn: put_req_header(conn, "content-type", "application/json")}
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer " <> @token)

  defp ingest(conn, batch), do: post(authed(conn), ~p"/api/sync/ingest", batch)

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
      "store_node_id" => "POS-07",
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
      conn = post(conn, ~p"/api/sync/ingest", full_batch())

      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "rejects an empty bearer token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer   ")
        |> post(~p"/api/sync/ingest", full_batch())

      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "accepts the token in x-api-token as well", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-api-token", @token)
        |> post(~p"/api/sync/ingest", full_batch())

      assert json_response(conn, 200)["batch"]["accepted"] == 4
    end

    test "accepts any non-empty token, because nothing issues tokens yet", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer literally-anything")
        |> post(~p"/api/sync/ingest", full_batch())

      assert json_response(conn, 200)["batch"]["accepted"] == 4
    end
  end

  describe "a malformed batch" do
    test "is rejected without a store_node_id", %{conn: conn} do
      conn = ingest(conn, %{"rows" => []})

      assert json_response(conn, 422)["error"] == "invalid_batch"
    end

    test "is rejected when rows is not a list", %{conn: conn} do
      conn = ingest(conn, %{"store_node_id" => "POS-07", "rows" => %{"nope" => true}})

      assert json_response(conn, 422)["detail"] =~ "rows must be a list"
    end

    test "is rejected when it carries too many rows", %{conn: conn} do
      rows = for n <- 1..1001, do: customer_row("cust-#{n}")
      conn = ingest(conn, %{"store_node_id" => "POS-07", "rows" => rows})

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

    test "stores the invoice with its customer, its line and its item", %{conn: conn} do
      ingest(conn, full_batch())

      invoice = Billing.get_by_client_id(:invoice, "inv-1") |> then(&Billing.get_invoice!(&1.id))

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

    test "accepts lines nested inside the invoice instead of as their own rows", %{conn: conn} do
      batch = %{
        "store_node_id" => "POS-07",
        "rows" => [
          item_row("item-1"),
          invoice_row("inv-1", %{
            "lines" => [line_data(%{"item_client_id" => "item-1", "client_id" => "nested-1"})]
          })
        ]
      }

      conn = ingest(conn, batch)
      assert json_response(conn, 200)["batch"]["rejected"] == 0

      invoice = Billing.get_by_client_id(:invoice, "inv-1") |> then(&Billing.get_invoice!(&1.id))
      assert [%{client_id: "nested-1"}] = invoice.lines
    end

    test "does not need the rows in dependency order", %{conn: conn} do
      batch = full_batch() |> Map.update!("rows", &Enum.reverse/1)

      conn = ingest(conn, batch)

      assert json_response(conn, 200)["batch"]["accepted"] == 4
      assert Billing.get_by_client_id(:invoice, "inv-1")
    end

    test "records which desk claimed the token, by digest and not in the clear", %{conn: conn} do
      ingest(conn, full_batch())

      assert [claim] = Sync.list_node_claims()
      assert claim.store_node_id == "POS-07"
      assert claim.batch_count == 1
      assert claim.row_count == 4
      refute claim.token_digest == @token
      assert claim.token_digest == :sha256 |> :crypto.hash(@token) |> Base.encode16(case: :lower)
    end

    test "counts further batches against the same claim", %{conn: conn} do
      ingest(conn, full_batch())
      ingest(conn, full_batch())

      assert [claim] = Sync.list_node_claims()
      assert claim.batch_count == 2
      assert claim.row_count == 8
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
        "store_node_id" => "POS-07",
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
    test "a re-sent invoice is never rewritten, even with different figures", %{conn: conn} do
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

      invoice = Billing.get_by_client_id(:invoice, "inv-1")
      assert Decimal.equal?(invoice.grand_total, Decimal.new("113280.00"))
    end

    test "a different invoice reusing a number on the same desk is rejected", %{conn: conn} do
      ingest(conn, full_batch())

      clash = %{
        "store_node_id" => "POS-07",
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

      other_desk =
        full_batch()
        |> Map.put("store_node_id", "POS-08")
        |> Map.update!("rows", fn rows ->
          Enum.map(rows, fn row ->
            Map.update!(row, "client_id", &(&1 <> "-b"))
          end)
        end)
        |> Map.update!("rows", fn rows ->
          Enum.map(rows, fn
            %{"type" => "invoice"} = row ->
              put_in(row, ["data", "customer_client_id"], "cust-1-b")

            %{"type" => "invoice_line"} = row ->
              Map.put(row, "invoice_client_id", "inv-1-b")

            row ->
              row
          end)
        end)

      assert json_response(ingest(conn, other_desk), 200)["batch"]["rejected"] == 0
      assert Repo.aggregate(Billing.Invoice, :count) == 2
    end
  end

  describe "per-row rejection" do
    test "one bad row does not take the good ones down with it", %{conn: conn} do
      batch = %{
        "store_node_id" => "POS-07",
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

      assert Billing.get_by_client_id(:invoice, "inv-1")
      refute Billing.get_by_client_id(:item, "item-bad")
    end

    test "an invalid invoice takes its own lines with it and nothing else", %{conn: conn} do
      batch = %{
        "store_node_id" => "POS-07",
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
        "store_node_id" => "POS-07",
        "rows" => [%{"type" => "customer", "data" => %{"name" => "X"}}]
      }

      assert [result] = json_response(ingest(conn, batch), 200)["results"]
      assert result["status"] == "rejected"
      assert result["errors"]["base"] == ["client_id is required"]
    end

    test "rejects an unknown row type", %{conn: conn} do
      batch = %{
        "store_node_id" => "POS-07",
        "rows" => [%{"client_id" => "x-1", "type" => "spaceship", "data" => %{}}]
      }

      assert [result] = json_response(ingest(conn, batch), 200)["results"]
      assert result["status"] == "rejected"
      assert hd(result["errors"]["base"]) =~ "type must be one of"
    end

    test "rejects a row whose data is not an object", %{conn: conn} do
      batch = %{
        "store_node_id" => "POS-07",
        "rows" => [%{"client_id" => "x-1", "type" => "customer", "data" => "nope"}]
      }

      assert [result] = json_response(ingest(conn, batch), 200)["results"]
      assert result["errors"]["base"] == ["data must be an object"]
    end

    test "rejects a line with no invoice to attach to", %{conn: conn} do
      batch = %{
        "store_node_id" => "POS-07",
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
        "store_node_id" => "POS-07",
        "rows" => [%{"client_id" => "line-1", "type" => "invoice_line", "data" => line_data()}]
      }

      assert [result] = json_response(ingest(conn, batch), 200)["results"]
      assert result["errors"]["base"] == ["invoice_client_id is required for an invoice_line row"]
    end
  end

  describe "what a desk is not allowed to decide" do
    test "the envelope's store_node_id overrides whatever a row claims", %{conn: conn} do
      batch = %{
        "store_node_id" => "POS-07",
        "rows" => [customer_row("cust-1", %{"store_node_id" => "POS-99"})]
      }

      ingest(conn, batch)

      assert Billing.get_by_client_id(:customer, "cust-1").store_node_id == "POS-07"
    end

    test "a raw customer_id in the payload is ignored", %{conn: conn} do
      other = Billing.create_customer!(%{name: "Someone Else", store_node_id: "POS-99"})

      batch = %{
        "store_node_id" => "POS-07",
        "rows" => [
          item_row("item-1"),
          invoice_row("inv-1", %{
            "customer_id" => other.id,
            "lines" => [line_data(%{"item_client_id" => "item-1"})]
          })
        ]
      }

      ingest(conn, batch)

      assert is_nil(Billing.get_by_client_id(:invoice, "inv-1").customer_id)
    end

    test "an invoice naming an unknown customer_client_id is stored as a counter sale", %{
      conn: conn
    } do
      batch = %{
        "store_node_id" => "POS-07",
        "rows" => [
          item_row("item-1"),
          invoice_row("inv-1", %{
            "customer_client_id" => "never-synced",
            "lines" => [line_data(%{"item_client_id" => "item-1"})]
          })
        ]
      }

      assert json_response(ingest(conn, batch), 200)["batch"]["rejected"] == 0
      assert is_nil(Billing.get_by_client_id(:invoice, "inv-1").customer_id)
    end
  end

  describe "upserts" do
    test "a customer re-sent with new details is updated in place", %{conn: conn} do
      ingest(conn, %{"store_node_id" => "POS-07", "rows" => [customer_row("cust-1")]})

      ingest(conn, %{
        "store_node_id" => "POS-07",
        "rows" => [customer_row("cust-1", %{"name" => "Thiruvalluvar Networks Pvt Ltd"})]
      })

      assert Repo.aggregate(Billing.Customer, :count) == 1

      assert Billing.get_by_client_id(:customer, "cust-1").name ==
               "Thiruvalluvar Networks Pvt Ltd"
    end

    test "an item re-sent with a new price is updated in place", %{conn: conn} do
      ingest(conn, %{"store_node_id" => "POS-07", "rows" => [item_row("item-1")]})

      ingest(conn, %{
        "store_node_id" => "POS-07",
        "rows" => [item_row("item-1", %{"rate" => "99000.00"})]
      })

      assert Repo.aggregate(Billing.Item, :count) == 1

      assert Decimal.equal?(
               Billing.get_by_client_id(:item, "item-1").rate,
               Decimal.new("99000.00")
             )
    end

    test "repricing an item does not change an invoice already issued at the old price", %{
      conn: conn
    } do
      ingest(conn, full_batch())

      ingest(conn, %{
        "store_node_id" => "POS-07",
        "rows" => [item_row("item-1", %{"rate" => "1.00"})]
      })

      line = Repo.one(from l in Billing.InvoiceLine, where: l.client_id == "line-1")
      assert Decimal.equal?(line.rate, Decimal.new("96000.00"))
    end
  end
end
