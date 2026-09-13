defmodule RealinvoiceCloudWeb.InvoiceLiveTest do
  # Not async: the live-update tests need the LiveView process to share this
  # test's database connection, which only shared sandbox mode allows.
  use RealinvoiceCloudWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import RealinvoiceCloud.AccountsFixtures
  import RealinvoiceCloud.BillingFixtures

  alias RealinvoiceCloud.Billing

  setup %{conn: conn} do
    %{conn: log_in_user(conn, user_fixture())}
  end

  describe "the invoice list" do
    setup do
      vaanavil = customer_fixture(%{name: "Vaanavil Systems Pvt Ltd", store_node_id: "POS-01"})
      kaveri = customer_fixture(%{name: "Kaveri Infotech LLP", store_node_id: "POS-02"})

      first =
        invoice_fixture(%{
          invoice_no: "RI-2026-0001",
          customer_id: vaanavil.id,
          store_node_id: "POS-01",
          date: ~D[2026-09-13],
          payment_type: "UPI",
          grand_total: "57230.00"
        })

      second =
        invoice_fixture(%{
          invoice_no: "RI-2026-0001",
          customer_id: kaveri.id,
          store_node_id: "POS-02",
          date: ~D[2026-09-01],
          payment_type: "Card",
          grand_total: "10030.00"
        })

      %{first: first, second: second}
    end

    test "lists every invoice with its columns", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/invoices")

      assert html =~ "RI-2026-0001"
      assert html =~ "Vaanavil Systems Pvt Ltd"
      assert html =~ "Kaveri Infotech LLP"
      assert html =~ "POS-01"
      assert html =~ "POS-02"
      assert html =~ "UPI"
      assert html =~ "13 Sep 2026"
      # Indian digit grouping, not thousands grouping
      assert html =~ "₹57,230.00"
      assert html =~ "2 invoices"
    end

    test "shows the total of the listed invoices", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/invoices")
      assert html =~ "₹67,260.00"
    end

    test "labels an invoice with no customer as a counter sale", %{conn: conn} do
      invoice_fixture(%{invoice_no: "RI-2026-0099", customer_id: nil})

      {:ok, _lv, html} = live(conn, ~p"/invoices")
      assert html =~ "Counter sale"
    end

    test "filters by node", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/invoices")

      html = lv |> form("#invoice-filters", %{"node" => "POS-02"}) |> render_change()

      assert html =~ "Kaveri Infotech LLP"
      refute html =~ "Vaanavil Systems Pvt Ltd"
      assert html =~ "1 invoice"
      assert_patched(lv, ~p"/invoices?node=POS-02")
    end

    test "filters by date range", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/invoices")

      html =
        lv
        |> form("#invoice-filters", %{"from" => "2026-09-10", "to" => "2026-09-20"})
        |> render_change()

      assert html =~ "Vaanavil Systems Pvt Ltd"
      refute html =~ "Kaveri Infotech LLP"
      assert html =~ "1 invoice"
    end

    test "searches by customer name and invoice number", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/invoices")

      html = lv |> form("#invoice-filters", %{"q" => "kaveri"}) |> render_change()
      assert html =~ "Kaveri Infotech LLP"
      refute html =~ "Vaanavil Systems Pvt Ltd"

      html = lv |> form("#invoice-filters", %{"q" => "no-such-invoice"}) |> render_change()
      assert html =~ "No matching invoices"
    end

    test "reads its filters from the query string", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/invoices?node=POS-02")

      assert html =~ "Kaveri Infotech LLP"
      refute html =~ "Vaanavil Systems Pvt Ltd"
    end

    test "clears filters", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/invoices?node=POS-02")

      html = lv |> element("button", "Clear") |> render_click()

      assert html =~ "Vaanavil Systems Pvt Ltd"
      assert html =~ "Kaveri Infotech LLP"
    end

    test "offers each seen node in the filter, and nothing else", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/invoices")

      assert has_element?(lv, ~s{#filter-node option[value="POS-01"]})
      assert has_element?(lv, ~s{#filter-node option[value="POS-02"]})
      refute has_element?(lv, ~s{#filter-node option[value="POS-03"]})
    end
  end

  describe "live updates" do
    test "an invoice created after mount appears without a reload", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/invoices")
      refute html =~ "RI-2026-7777"

      invoice_fixture(%{invoice_no: "RI-2026-7777", store_node_id: "POS-09"})

      html = render(lv)
      assert html =~ "RI-2026-7777"
      assert html =~ "1 invoice"
      # A brand new desk becomes selectable in the filter straight away.
      assert has_element?(lv, ~s{#filter-node option[value="POS-09"]})
    end

    test "an invoice that does not match the active filter is left out", %{conn: conn} do
      invoice_fixture(%{invoice_no: "RI-2026-0001", store_node_id: "POS-01"})

      {:ok, lv, _html} = live(conn, ~p"/invoices?node=POS-01")

      invoice_fixture(%{invoice_no: "RI-2026-8888", store_node_id: "POS-02"})

      html = render(lv)
      refute html =~ "RI-2026-8888"
      assert html =~ "1 invoice"
    end

    test "the dashboard recomputes when an invoice arrives", %{conn: conn} do
      invoice_fixture(%{date: Date.utc_today(), grand_total: "100.00"})

      {:ok, lv, html} = live(conn, ~p"/")
      assert html =~ "₹100.00"

      invoice_fixture(%{date: Date.utc_today(), grand_total: "900.00"})

      assert render(lv) =~ "₹1,000.00"
    end
  end

  describe "the invoice detail view" do
    test "shows the line items and the summary exactly as stored", %{conn: conn} do
      customer =
        customer_fixture(%{
          name: "Nandhini Traders",
          gstin: "29AACCN5678K1Z3",
          place_of_supply: "Karnataka"
        })

      item =
        item_fixture(%{
          item_code: "NW-CAT6-305",
          description: "Cat6 UTP Cable 305m Box",
          uom: "Box"
        })

      invoice =
        invoice_fixture(%{
          invoice_no: "RI-2026-0007",
          customer_id: customer.id,
          date: ~D[2026-09-13],
          payment_type: "Card",
          created_by: "Anitha R (till-1)",
          subtotal: "15700.00",
          cgst: "0.00",
          sgst: "0.00",
          igst: "2826.00",
          grand_total: "18526.00",
          lines: [
            %{
              item_id: item.id,
              qty: "2",
              rate: "7850.00",
              tax_rate: "18.00",
              line_total: "15700.00"
            }
          ]
        })

      {:ok, _lv, html} = live(conn, ~p"/invoices/#{invoice}")

      assert html =~ "RI-2026-0007"
      assert html =~ "Anitha R (till-1)"
      assert html =~ "Nandhini Traders"
      assert html =~ "29AACCN5678K1Z3"
      assert html =~ "Cat6 UTP Cable 305m Box"
      assert html =~ "NW-CAT6-305"
      assert html =~ "₹7,850.00"
      assert html =~ "18%"
      assert html =~ "₹15,700.00"
      assert html =~ "₹2,826.00"
      assert html =~ "₹18,526.00"
      # An inter-state sale shows IGST only, with no empty CGST/SGST rows.
      assert html =~ "IGST"
      refute html =~ ">CGST<"
    end

    test "shows CGST and SGST for an intra-state sale", %{conn: conn} do
      invoice = invoice_fixture(%{cgst: "9.00", sgst: "9.00", igst: "0.00"})

      {:ok, _lv, html} = live(conn, ~p"/invoices/#{invoice}")

      assert html =~ "CGST"
      assert html =~ "SGST"
      refute html =~ ">IGST<"
    end

    test "says so when there is no customer on the invoice", %{conn: conn} do
      invoice = invoice_fixture(%{customer_id: nil})

      {:ok, _lv, html} = live(conn, ~p"/invoices/#{invoice}")

      assert html =~ "A counter sale"
    end

    test "is reachable from the list", %{conn: conn} do
      invoice = invoice_fixture(%{invoice_no: "RI-2026-0001"})

      {:ok, lv, _html} = live(conn, ~p"/invoices")

      {:ok, _show_lv, html} =
        lv
        |> element(~s{a[href="/invoices/#{invoice.id}"]})
        |> render_click()
        |> follow_redirect(conn, ~p"/invoices/#{invoice}")

      assert html =~ "Line items"
    end

    test "404s for an unknown invoice", %{conn: conn} do
      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/invoices/999999") end
    end
  end

  test "the list requires a signed-in user" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(build_conn(), ~p"/invoices")
  end

  test "the broadcast contract is what the LiveView listens for" do
    # Guards the coupling between Billing.create_invoice/1 and the LiveViews:
    # if the message shape changes, this fails rather than the live updates
    # silently going quiet.
    Billing.subscribe()
    invoice = invoice_fixture()
    assert_receive {:invoice_created, %{id: id}}
    assert id == invoice.id
  end
end
