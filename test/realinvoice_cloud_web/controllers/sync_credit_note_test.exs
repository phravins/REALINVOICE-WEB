defmodule RealinvoiceCloudWeb.SyncCreditNoteTest do
  @moduledoc """
  Credit notes arriving over the ingest endpoint, on the same terms as
  everything else: authenticated by node token, idempotent per (node, client_id),
  append-only.
  """
  use RealinvoiceCloudWeb.ConnCase, async: true

  import RealinvoiceCloud.NodesFixtures

  alias RealinvoiceCloud.Billing
  alias RealinvoiceCloud.Billing.CreditNote
  alias RealinvoiceCloud.Billing.CreditNoteLine
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

  defp results(conn),
    do: conn |> json_response(200) |> Map.fetch!("results") |> Map.new(&{&1["client_id"], &1})

  defp item_row(client_id \\ "item-1") do
    %{
      "client_id" => client_id,
      "type" => "item",
      "data" => %{
        "item_code" => "SW-CORE-48P",
        "description" => "48-port Core Switch",
        "rate" => "1000.00",
        "tax_rate" => "18.00",
        "uom" => "Nos"
      }
    }
  end

  defp invoice_row(client_id \\ "inv-1") do
    %{
      "client_id" => client_id,
      "type" => "invoice",
      "data" => %{
        "invoice_no" => "RI-2026-0001",
        "date" => "2026-09-14",
        "subtotal" => "2000.00",
        "cgst" => "180.00",
        "sgst" => "180.00",
        "igst" => "0.00",
        "grand_total" => "2360.00",
        "payment_type" => "Card",
        "created_by" => "Anitha R (till-1)",
        "lines" => [
          %{
            "client_id" => "line-1",
            "item_client_id" => "item-1",
            "qty" => "2",
            "rate" => "1000.00",
            "tax_rate" => "18.00",
            "line_total" => "2000.00"
          }
        ]
      }
    }
  end

  defp credit_note_row(overrides \\ %{}) do
    %{
      "client_id" => "cn-1",
      "type" => "credit_note",
      "data" =>
        Map.merge(
          %{
            "credit_note_no" => "CN-2026-0001",
            "date" => "2026-09-14",
            "original_invoice_client_id" => "inv-1",
            "reason" => "One switch returned",
            "subtotal" => "1000.00",
            "cgst" => "90.00",
            "sgst" => "90.00",
            "igst" => "0.00",
            "grand_total" => "1180.00",
            "created_by" => "Anitha R (till-1)",
            "lines" => [
              %{
                "client_id" => "cnl-1",
                "item_client_id" => "item-1",
                "qty" => "1",
                "rate" => "1000.00",
                "tax_rate" => "18.00",
                "line_total" => "1000.00"
              }
            ]
          },
          overrides
        )
    }
  end

  defp full_batch(overrides \\ %{}) do
    %{"rows" => [item_row(), invoice_row(), credit_note_row(overrides)]}
  end

  describe "a credit note in the same batch as its invoice" do
    test "is accepted and linked to that invoice", %{conn: conn, node: node} do
      conn = ingest(conn, full_batch())

      assert json_response(conn, 200)["batch"]["rejected"] == 0
      assert results(conn)["cn-1"]["action"] == "inserted"

      note = Billing.get_by_client_id(:credit_note, node.id, "cn-1")
      invoice = Billing.get_by_client_id(:invoice, node.id, "inv-1")

      assert note.original_invoice_id == invoice.id
      assert note.credit_note_no == "CN-2026-0001"
      assert note.reason == "One switch returned"
      assert Decimal.equal?(note.grand_total, Decimal.new("1180.00"))
    end

    test "takes the desk from the token, not the payload", %{conn: conn, node: node} do
      ingest(conn, full_batch(%{"store_node_id" => "I-AM-LYING"}))

      note = Billing.get_by_client_id(:credit_note, node.id, "cn-1")
      assert note.store_node_id == "POS-07"
      assert note.node_id == node.id
    end

    test "stores its lines with the item resolved", %{conn: conn, node: node} do
      ingest(conn, full_batch())

      note = Billing.get_credit_note!(Billing.get_by_client_id(:credit_note, node.id, "cn-1").id)

      assert [line] = note.lines
      assert line.client_id == "cnl-1"
      assert line.item.item_code == "SW-CORE-48P"
      assert Decimal.equal?(line.line_total, Decimal.new("1000.00"))
    end

    test "nets the invoice down", %{conn: conn} do
      ingest(conn, full_batch())

      assert [listed] = Billing.list_invoices()
      assert listed.credit_note_count == 1
      assert Decimal.equal?(Billing.net_total(listed), Decimal.new("1180.00"))
    end
  end

  describe "a credit note against an invoice from an earlier batch" do
    test "is linked to the stored invoice", %{conn: conn, node: node} do
      ingest(conn, %{"rows" => [item_row(), invoice_row()]})

      conn = ingest(conn, %{"rows" => [credit_note_row()]})

      assert json_response(conn, 200)["batch"]["rejected"] == 0

      note = Billing.get_by_client_id(:credit_note, node.id, "cn-1")
      assert note.original_invoice_id == Billing.get_by_client_id(:invoice, node.id, "inv-1").id
    end
  end

  describe "retrying" do
    test "re-sending the same credit note does not double count it", %{conn: conn} do
      ingest(conn, full_batch())
      retry = ingest(conn, full_batch())

      assert json_response(retry, 200)["batch"]["rejected"] == 0
      assert results(retry)["cn-1"]["action"] == "unchanged"
      assert results(retry)["cnl-1"] == nil

      assert Repo.aggregate(CreditNote, :count) == 1
      assert Repo.aggregate(CreditNoteLine, :count) == 1

      # The invoice is credited once, not twice.
      assert [listed] = Billing.list_invoices()
      assert listed.credit_note_count == 1
      assert Decimal.equal?(Billing.net_total(listed), Decimal.new("1180.00"))
    end

    test "the retry reports the same record id", %{conn: conn} do
      first = conn |> ingest(full_batch()) |> results()
      second = conn |> ingest(full_batch()) |> results()

      assert first["cn-1"]["id"] == second["cn-1"]["id"]
    end

    test "a credit note already stored is never rewritten", %{conn: conn, node: node} do
      ingest(conn, full_batch())

      amended = full_batch(%{"grand_total" => "1.00", "reason" => "Changed my mind"})
      assert results(ingest(conn, amended))["cn-1"]["action"] == "unchanged"

      note = Billing.get_by_client_id(:credit_note, node.id, "cn-1")
      assert Decimal.equal?(note.grand_total, Decimal.new("1180.00"))
      assert note.reason == "One switch returned"
    end

    test "retrying only the line, after its note landed earlier, is a no-op", %{conn: conn} do
      # The note arrives with its line sent as a separate row.
      line_row = %{
        "client_id" => "cnl-standalone",
        "type" => "credit_note_line",
        "credit_note_client_id" => "cn-1",
        "data" => %{
          "item_client_id" => "item-1",
          "qty" => "1",
          "rate" => "1000.00",
          "tax_rate" => "18.00",
          "line_total" => "1000.00"
        }
      }

      first = %{
        "rows" => [
          item_row(),
          invoice_row(),
          put_in(credit_note_row(), ["data", "lines"], []),
          line_row
        ]
      }

      assert json_response(ingest(conn, first), 200)["batch"]["rejected"] == 0

      # The worker's ack was lost, so it resends just the line.
      retry = results(ingest(conn, %{"rows" => [line_row]}))

      assert retry["cnl-standalone"]["status"] == "accepted"
      assert retry["cnl-standalone"]["action"] == "unchanged"
      assert Repo.aggregate(CreditNoteLine, :count) == 1
    end
  end

  describe "standalone credit_note_line rows" do
    test "are applied as part of their note", %{conn: conn, node: node} do
      batch = %{
        "rows" => [
          item_row(),
          invoice_row(),
          credit_note_row() |> put_in(["data", "lines"], []),
          %{
            "client_id" => "cnl-2",
            "type" => "credit_note_line",
            "credit_note_client_id" => "cn-1",
            "data" => %{
              "item_client_id" => "item-1",
              "qty" => "1",
              "rate" => "1000.00",
              "tax_rate" => "18.00",
              "line_total" => "1000.00"
            }
          }
        ]
      }

      conn = ingest(conn, batch)
      assert json_response(conn, 200)["batch"]["rejected"] == 0
      assert results(conn)["cnl-2"]["status"] == "accepted"

      note = Billing.get_credit_note!(Billing.get_by_client_id(:credit_note, node.id, "cn-1").id)
      assert [%{client_id: "cnl-2"}] = note.lines
    end

    test "are rejected when they name no note", %{conn: conn} do
      batch = %{
        "rows" => [
          %{"client_id" => "cnl-orphan", "type" => "credit_note_line", "data" => %{"qty" => "1"}}
        ]
      }

      assert results(ingest(conn, batch))["cnl-orphan"]["errors"]["base"] == [
               "credit_note_client_id is required for a credit_note_line row"
             ]
    end
  end

  describe "rejection" do
    test "a credit note with no invoice to credit is rejected", %{conn: conn} do
      batch = %{"rows" => [item_row(), credit_note_row()]}

      result = results(ingest(conn, batch))["cn-1"]

      assert result["status"] == "rejected"
      assert hd(result["errors"]["base"]) =~ "no invoice in this batch or already stored"
      assert Repo.aggregate(CreditNote, :count) == 0
    end

    test "a credit note naming no invoice at all is rejected", %{conn: conn} do
      batch = %{
        "rows" => [
          item_row(),
          invoice_row(),
          credit_note_row() |> update_in(["data"], &Map.delete(&1, "original_invoice_client_id"))
        ]
      }

      result = results(ingest(conn, batch))["cn-1"]

      assert result["status"] == "rejected"

      assert result["errors"]["base"] == [
               "original_invoice_client_id is required for a credit_note row"
             ]
    end

    test "a credit note whose invoice was rejected goes with it", %{conn: conn} do
      broken_invoice = invoice_row() |> put_in(["data", "grand_total"], "-1.00")
      batch = %{"rows" => [item_row(), broken_invoice, credit_note_row()]}

      result = results(ingest(conn, batch))

      assert result["inv-1"]["status"] == "rejected"
      assert result["cn-1"]["errors"]["base"] == ["its original invoice was rejected"]
      assert Repo.aggregate(CreditNote, :count) == 0
    end

    test "an invalid credit note takes its lines with it and nothing else", %{conn: conn} do
      batch = %{
        "rows" => [
          item_row(),
          invoice_row(),
          credit_note_row(%{"grand_total" => "-5.00"})
        ]
      }

      result = results(ingest(conn, batch))

      assert result["inv-1"]["status"] == "accepted"
      assert result["cn-1"]["status"] == "rejected"
      assert Repo.aggregate(CreditNote, :count) == 0
      assert Repo.aggregate(CreditNoteLine, :count) == 0
    end

    test "a credit note cannot be attached to another desk's invoice", %{conn: conn} do
      # POS-07 syncs an invoice under client id inv-1 …
      ingest(conn, %{"rows" => [item_row(), invoice_row()]})

      # … and POS-08 sends a credit note naming the same client id.
      {_other, other_token} = node_with_token(%{name: "POS-08"})

      other_conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> other_token)

      result = results(ingest(other_conn, %{"rows" => [credit_note_row()]}))["cn-1"]

      assert result["status"] == "rejected"
      assert Repo.aggregate(CreditNote, :count) == 0
    end
  end

  describe "client ids are scoped per node" do
    test "two desks may use the same credit note client id", %{conn: conn} do
      {_other, other_token} = node_with_token(%{name: "POS-08"})

      other_conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> other_token)

      assert json_response(ingest(conn, full_batch()), 200)["batch"]["rejected"] == 0
      assert json_response(ingest(other_conn, full_batch()), 200)["batch"]["rejected"] == 0

      assert Repo.aggregate(CreditNote, :count) == 2
    end
  end

  describe "authentication" do
    test "an unknown token cannot post a credit note", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer rin_not-a-real-token")
        |> post(~p"/api/sync/ingest", full_batch())

      assert json_response(conn, 401)["error"] == "unauthorized"
      assert Repo.aggregate(CreditNote, :count) == 0
    end
  end
end
