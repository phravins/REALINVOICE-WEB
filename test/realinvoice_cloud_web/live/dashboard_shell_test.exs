defmodule RealinvoiceCloudWeb.DashboardShellTest do
  use RealinvoiceCloudWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import RealinvoiceCloud.AccountsFixtures

  @sections [
    {"/", "Dashboard"},
    {"/invoices", "Invoices"},
    {"/customers", "Customers"},
    {"/items", "Items"},
    {"/nodes", "Nodes"},
    {"/settings", "Settings"}
  ]

  describe "when signed out" do
    for {path, name} <- @sections do
      test "#{name} redirects to the login page", %{conn: conn} do
        assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, unquote(path))
      end
    end
  end

  describe "when signed in" do
    setup %{conn: conn} do
      %{conn: log_in_user(conn, user_fixture())}
    end

    for {path, name} <- @sections do
      test "#{name} renders with every section in the sidebar", %{conn: conn} do
        {:ok, _lv, html} = live(conn, unquote(path))

        for {section_path, section_name} <- @sections do
          assert html =~ ~s(href="#{section_path}")
          assert html =~ section_name
        end
      end
    end

    test "the dashboard falls back to its empty state with no invoices", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "No data yet"
      assert html =~ "once your billing desks start syncing"
    end

    test "Nodes is still a placeholder", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/nodes")

      assert html =~ "Coming soon"
      assert html =~ "Nodes arrives once the desktop app starts syncing."
    end

    test "the built sections render their own empty states", %{conn: conn} do
      for {path, empty} <- [
            {"/invoices", "No invoices yet"},
            {"/customers", "No customers yet"},
            {"/items", "No items yet"}
          ] do
        {:ok, _lv, html} = live(conn, path)
        refute html =~ "Coming soon"
        assert html =~ empty
      end
    end

    test "only the current section is marked active", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/invoices")

      assert html =~ ~r/href="\/invoices"[^>]*data-active="true"/
      assert html =~ ~r/href="\/customers"[^>]*data-active="false"/
    end
  end

  describe "settings account section" do
    test "shows the signed-in account's email and role", %{conn: conn} do
      user = staff_user_fixture(%{email: "owner@example.com", role: "owner"})

      {:ok, _lv, html} = live(log_in_user(conn, user), ~p"/settings")

      assert html =~ "Account"
      assert html =~ "owner@example.com"
      assert html =~ "owner"
      assert html =~ "Confirmed"
    end

    test "shows the staff role for a staff account", %{conn: conn} do
      user = staff_user_fixture(%{email: "staff@example.com"})

      {:ok, _lv, html} = live(log_in_user(conn, user), ~p"/settings")

      assert user.role == "staff"
      assert html =~ "back-office staff"
    end
  end
end
