defmodule RealinvoiceCloudWeb.CreditNoteLiveTest do
  @moduledoc """
  What an admin sees once credit notes start arriving: the Credits column and
  filter on the list, the linked notes and net on the detail page, and a
  dashboard that never quotes gross revenue as if the credits had not happened.
  """
  use RealinvoiceCloudWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import RealinvoiceCloud.AccountsFixtures
  import RealinvoiceCloud.BillingFixtures
  import RealinvoiceCloud.NodesFixtures

  setup %{conn: conn} do
    %{conn: log_in_user(conn, user_fixture())}
  end

  describe "the invoice list" do
    setup do
      credited = invoice_fixture(%{invoice_no: "RI-CREDITED", grand_total: "1000.00"})
      clean = invoice_fixture(%{invoice_no: "RI-CLEAN", grand_total: "500.00"})

      credit_note_fixture(%{
        original_invoice_id: credited.id,
        credit_note_no: "CN-0001",
        grand_total: "250.00"
      })

      %{credited: credited, clean: clean}
    end

    test "shows a Credits column with what was credited", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/invoices")

      assert html =~ "Credits"
      assert html =~ "−₹250.00"
    end

    test "shows the net alongside the struck-out gross for a credited invoice", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/invoices")

      assert html =~ "₹750.00"
      assert html =~ "line-through"
      assert html =~ "₹1,000.00"
    end

    test "totals the list net of credits", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/invoices")

      # 1500 billed, 250 credited.
      assert html =~ "Billed ₹1,500.00 less ₹250.00 credited"
      assert html =~ "₹1,250.00"
    end

    test "filters to corrected invoices", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/invoices")

      html = lv |> form("#invoice-filters", %{"credited" => "credited"}) |> render_change()

      assert html =~ "RI-CREDITED"
      refute html =~ "RI-CLEAN"
      assert html =~ "1 invoice"
      assert_patched(lv, ~p"/invoices?credited=credited")
    end

    test "filters to invoices with no corrections", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/invoices")

      html = lv |> form("#invoice-filters", %{"credited" => "uncredited"}) |> render_change()

      assert html =~ "RI-CLEAN"
      refute html =~ "RI-CREDITED"
      assert html =~ "1 invoice"
    end

    test "reads the filter from the query string", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/invoices?credited=credited")

      assert html =~ "RI-CREDITED"
      refute html =~ "RI-CLEAN"
    end

    test "an uncredited invoice shows no credit figure", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/invoices")

      html = lv |> form("#invoice-filters", %{"credited" => "uncredited"}) |> render_change()

      assert html =~ "RI-CLEAN"
      refute html =~ "−₹"
    end
  end

  describe "the invoice detail page" do
    setup do
      invoice = invoice_fixture(%{invoice_no: "RI-2026-0001", grand_total: "2360.00"})

      note =
        credit_note_fixture(%{
          original_invoice_id: invoice.id,
          credit_note_no: "CN-2026-0001",
          reason: "One switch returned",
          grand_total: "1180.00",
          created_by: "Anitha R (till-1)"
        })

      %{invoice: invoice, note: note}
    end

    test "lists the credit notes raised against it", %{conn: conn, invoice: invoice} do
      {:ok, _lv, html} = live(conn, ~p"/invoices/#{invoice}")

      assert html =~ "Credit notes"
      assert html =~ "CN-2026-0001"
      assert html =~ "One switch returned"
      assert html =~ "Anitha R (till-1)"
    end

    test "shows the net after credits", %{conn: conn, invoice: invoice} do
      {:ok, _lv, html} = live(conn, ~p"/invoices/#{invoice}")

      assert html =~ "Net after credits"
      assert html =~ "₹1,180.00"
      # The gross is still shown, so the netting is visible rather than silent.
      assert html =~ "₹2,360.00"
    end

    test "shows the credit note's own line items", %{conn: conn, invoice: invoice} do
      {:ok, _lv, html} = live(conn, ~p"/invoices/#{invoice}")

      assert html =~ "42U Server Rack Pro"
    end

    test "an uncredited invoice shows no credit section at all", %{conn: conn} do
      invoice = invoice_fixture(%{invoice_no: "RI-CLEAN"})

      {:ok, _lv, html} = live(conn, ~p"/invoices/#{invoice}")

      refute html =~ "Net after credits"
      refute html =~ "Credit notes"
    end
  end

  describe "the dashboard" do
    test "quotes revenue net of credit notes, showing both parts", %{conn: conn} do
      today = Date.utc_today()
      invoice = invoice_fixture(%{date: today, grand_total: "1000.00"})

      credit_note_fixture(%{
        original_invoice_id: invoice.id,
        date: today,
        grand_total: "250.00"
      })

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "₹750.00"
      assert html =~ "₹1,000.00 billed less ₹250.00 credited"
    end

    test "says nothing about credits on a day with none", %{conn: conn} do
      invoice_fixture(%{date: Date.utc_today(), grand_total: "1000.00"})

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "₹1,000.00"
      refute html =~ "credited"
    end

    test "nets the per-node breakdown too", %{conn: conn} do
      today = Date.utc_today()
      invoice = invoice_fixture(%{date: today, store_node_id: "POS-01", grand_total: "1000.00"})
      invoice_fixture(%{date: today, store_node_id: "POS-02", grand_total: "400.00"})

      credit_note_fixture(%{
        original_invoice_id: invoice.id,
        date: today,
        store_node_id: "POS-01",
        grand_total: "250.00"
      })

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "less ₹250.00 credited"
      assert html =~ "₹750.00"
      assert html =~ "₹400.00"
    end
  end

  describe "live updates when a credit note syncs in" do
    defp sync_post(token, payload) do
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)
      |> post(~p"/api/sync/ingest", payload)
    end

    defp batch_with_credit_note do
      %{
        "rows" => [
          %{
            "client_id" => "item-1",
            "type" => "item",
            "data" => %{
              "item_code" => "SW-1",
              "rate" => "1000.00",
              "tax_rate" => "18.00",
              "uom" => "Nos"
            }
          },
          %{
            "client_id" => "inv-1",
            "type" => "invoice",
            "data" => %{
              "invoice_no" => "RI-SYNCED-0001",
              "date" => Date.to_iso8601(Date.utc_today()),
              "subtotal" => "1000.00",
              "cgst" => "0.00",
              "sgst" => "0.00",
              "igst" => "0.00",
              "grand_total" => "1000.00",
              "payment_type" => "Card",
              "lines" => [
                %{
                  "client_id" => "l-1",
                  "item_client_id" => "item-1",
                  "qty" => "1",
                  "rate" => "1000.00",
                  "tax_rate" => "18.00",
                  "line_total" => "1000.00"
                }
              ]
            }
          }
        ]
      }
    end

    defp credit_note_batch do
      %{
        "rows" => [
          %{
            "client_id" => "cn-1",
            "type" => "credit_note",
            "data" => %{
              "credit_note_no" => "CN-SYNCED-0001",
              "date" => Date.to_iso8601(Date.utc_today()),
              "original_invoice_client_id" => "inv-1",
              "reason" => "Returned",
              "subtotal" => "250.00",
              "cgst" => "0.00",
              "sgst" => "0.00",
              "igst" => "0.00",
              "grand_total" => "250.00",
              "lines" => [
                %{
                  "client_id" => "cnl-1",
                  "item_client_id" => "item-1",
                  "qty" => "1",
                  "rate" => "250.00",
                  "tax_rate" => "0.00",
                  "line_total" => "250.00"
                }
              ]
            }
          }
        ]
      }
    end

    test "the dashboard's revenue drops without a reload", %{conn: conn} do
      {_node, token} = node_with_token(%{name: "POS-07"})
      sync_post(token, batch_with_credit_note())

      {:ok, lv, html} = live(conn, ~p"/")
      assert html =~ "₹1,000.00"

      sync_post(token, credit_note_batch())

      html = render(lv)
      assert html =~ "₹750.00"
      assert html =~ "less ₹250.00 credited"
    end

    test "the invoice list's row updates in place", %{conn: conn} do
      {_node, token} = node_with_token(%{name: "POS-07"})
      sync_post(token, batch_with_credit_note())

      {:ok, lv, html} = live(conn, ~p"/invoices")
      assert html =~ "RI-SYNCED-0001"
      refute html =~ "−₹250.00"

      sync_post(token, credit_note_batch())

      html = render(lv)
      assert html =~ "−₹250.00"
      assert html =~ "₹750.00"
      # Still one row, not a duplicate.
      assert html =~ "1 invoice"
    end

    test "an open invoice detail page picks up the new note", %{conn: conn} do
      {node, token} = node_with_token(%{name: "POS-07"})
      sync_post(token, batch_with_credit_note())
      invoice = RealinvoiceCloud.Billing.get_by_client_id(:invoice, node.id, "inv-1")

      {:ok, lv, html} = live(conn, ~p"/invoices/#{invoice}")
      refute html =~ "Net after credits"

      sync_post(token, credit_note_batch())

      html = render(lv)
      assert html =~ "Net after credits"
      assert html =~ "CN-SYNCED-0001"
      assert html =~ "₹750.00"
    end

    test "a credit note for a different invoice leaves this page alone", %{conn: conn} do
      {node, token} = node_with_token(%{name: "POS-07"})
      sync_post(token, batch_with_credit_note())
      invoice = RealinvoiceCloud.Billing.get_by_client_id(:invoice, node.id, "inv-1")

      other = invoice_fixture(%{invoice_no: "RI-OTHER"})

      {:ok, lv, _html} = live(conn, ~p"/invoices/#{invoice}")

      credit_note_fixture(%{original_invoice_id: other.id, credit_note_no: "CN-OTHER"})

      html = render(lv)
      refute html =~ "CN-OTHER"
      refute html =~ "Net after credits"
    end
  end
end
