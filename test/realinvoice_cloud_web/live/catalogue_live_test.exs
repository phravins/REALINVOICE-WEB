defmodule RealinvoiceCloudWeb.CatalogueLiveTest do
  use RealinvoiceCloudWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import RealinvoiceCloud.AccountsFixtures
  import RealinvoiceCloud.BillingFixtures

  setup %{conn: conn} do
    %{conn: log_in_user(conn, user_fixture())}
  end

  describe "the customer list" do
    setup do
      nandhini =
        customer_fixture(%{
          name: "Nandhini Traders",
          gstin: "29AACCN5678K1Z3",
          place_of_supply: "Karnataka",
          mobile: "+91 98861 44556",
          store_node_id: "POS-01"
        })

      kaveri =
        customer_fixture(%{
          name: "Kaveri Infotech LLP",
          gstin: "33AAGCK9012P1Z9",
          place_of_supply: "Tamil Nadu",
          mobile: "+91 90031 77889",
          store_node_id: "POS-02"
        })

      %{nandhini: nandhini, kaveri: kaveri}
    end

    test "lists every customer with its columns", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/customers")

      assert html =~ "Nandhini Traders"
      assert html =~ "29AACCN5678K1Z3"
      assert html =~ "Karnataka"
      assert html =~ "+91 98861 44556"
      assert html =~ "Kaveri Infotech LLP"
      assert html =~ "2 customers"
    end

    test "searches by name", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/customers")

      html = lv |> form("#customer-filters", %{"q" => "kaveri"}) |> render_change()

      assert html =~ "Kaveri Infotech LLP"
      refute html =~ "Nandhini Traders"
      assert html =~ "1 customer"
    end

    test "searches by GSTIN and mobile", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/customers")

      assert lv
             |> form("#customer-filters", %{"q" => "29AACCN"})
             |> render_change() =~ "Nandhini Traders"

      assert lv
             |> form("#customer-filters", %{"q" => "90031"})
             |> render_change() =~ "Kaveri Infotech LLP"
    end

    test "says so when nothing matches", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/customers")

      html = lv |> form("#customer-filters", %{"q" => "nobody"}) |> render_change()
      assert html =~ "No matching customers"
    end

    test "reads its filters from the query string", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/customers?q=nandhini")

      assert html =~ "Nandhini Traders"
      refute html =~ "Kaveri Infotech LLP"
    end

    test "offers no way to create or edit a customer", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/customers")

      refute html =~ "New customer"
      refute html =~ "Edit"
      refute html =~ "Delete"
    end
  end

  describe "the item list" do
    setup do
      rack =
        item_fixture(%{
          item_code: "RK-42U-PRO",
          description: "42U Server Rack Pro",
          rate: "48500.00",
          tax_rate: "18.00",
          uom: "Nos",
          store_node_id: "POS-01"
        })

      licence =
        item_fixture(%{
          item_code: "SW-ABCOS-ENT",
          description: "aBCOS Enterprise Lic",
          rate: "125000.00",
          tax_rate: "18.00",
          uom: "Lic",
          store_node_id: "POS-02"
        })

      %{rack: rack, licence: licence}
    end

    test "lists every item with its columns", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/items")

      assert html =~ "RK-42U-PRO"
      assert html =~ "42U Server Rack Pro"
      assert html =~ "Nos"
      assert html =~ "₹48,500.00"
      assert html =~ "18%"
      assert html =~ "aBCOS Enterprise Lic"
      assert html =~ "₹1,25,000.00"
      assert html =~ "2 items"
    end

    test "searches by code and description", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/items")

      html = lv |> form("#item-filters", %{"q" => "abcos"}) |> render_change()
      assert html =~ "aBCOS Enterprise Lic"
      refute html =~ "42U Server Rack Pro"

      html = lv |> form("#item-filters", %{"q" => "RK-42U"}) |> render_change()
      assert html =~ "42U Server Rack Pro"
      refute html =~ "aBCOS Enterprise Lic"
    end

    test "filters by node", %{conn: conn, licence: licence} do
      # The node dropdown is built from desks that have sent invoices, so
      # POS-02 needs one — billed against the item already in the catalogue.
      invoice_fixture(%{
        store_node_id: "POS-02",
        lines: [
          %{
            item_id: licence.id,
            qty: "1",
            rate: licence.rate,
            tax_rate: licence.tax_rate,
            line_total: licence.rate
          }
        ]
      })

      {:ok, lv, _html} = live(conn, ~p"/items")

      html = lv |> form("#item-filters", %{"node" => "POS-02"}) |> render_change()

      assert html =~ "aBCOS Enterprise Lic"
      refute html =~ "42U Server Rack Pro"
    end

    test "says so when nothing matches", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/items")

      html = lv |> form("#item-filters", %{"q" => "nothing"}) |> render_change()
      assert html =~ "No matching items"
    end

    test "offers no way to create or edit an item", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/items")

      refute html =~ "New item"
      refute html =~ "Edit"
      refute html =~ "Delete"
    end
  end

  describe "the dashboard" do
    test "shows real figures once invoices exist", %{conn: conn} do
      today = Date.utc_today()

      invoice_fixture(%{date: today, store_node_id: "POS-01", grand_total: "56758.00"})
      invoice_fixture(%{date: today, store_node_id: "POS-02", grand_total: "20060.00"})

      {:ok, _lv, html} = live(conn, ~p"/")

      refute html =~ "No data yet"
      assert html =~ "Revenue today"
      assert html =~ "₹76,818.00"
      assert html =~ "Revenue by node, today"
      assert html =~ "POS-01"
      assert html =~ "POS-02"
      assert html =~ "₹56,758.00"
      assert html =~ "₹20,060.00"
      # POS-01 took the larger share, so it is named as the busiest desk.
      assert html =~ "Busiest desk today"
    end

    test "falls back to the empty state with no invoices", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "No data yet"
      refute html =~ "Revenue by node"
    end
  end

  test "every list requires a signed-in user" do
    for path <- ["/customers", "/items"] do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), path)
    end
  end
end
