defmodule RealinvoiceCloudWeb.NodeLiveTest do
  use RealinvoiceCloudWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import RealinvoiceCloud.AccountsFixtures
  import RealinvoiceCloud.NodesFixtures

  alias RealinvoiceCloud.Nodes

  defp owner(%{conn: conn}) do
    %{conn: log_in_user(conn, staff_user_fixture(%{role: "owner"}))}
  end

  describe "access" do
    test "an owner may manage nodes", %{conn: conn} do
      conn = log_in_user(conn, staff_user_fixture(%{role: "owner"}))

      {:ok, _lv, html} = live(conn, ~p"/nodes")
      assert html =~ "Register new node"
    end

    test "a staff user is turned away", %{conn: conn} do
      conn = log_in_user(conn, staff_user_fixture(%{role: "staff"}))

      assert {:error, {:redirect, %{to: "/settings", flash: flash}}} = live(conn, ~p"/nodes")
      assert flash["error"] =~ "Only an owner"
    end

    test "a signed-out visitor is sent to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/nodes")
    end
  end

  describe "registering a node" do
    setup :owner

    test "shows the token exactly once, and never again", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/nodes")

      lv |> element("button", "Register new node") |> render_click()

      html =
        lv
        |> form("#node-registration", %{"node" => %{"name" => "POS-03"}})
        |> render_submit()

      assert html =~ "POS-03 is registered"
      assert html =~ "cannot be shown again"

      token = extract_token(html)
      assert String.starts_with?(token, "rin_")

      # It is gone from the page as soon as the panel is dismissed …
      html = lv |> element("#issued-token button", "Done") |> render_click()
      refute html =~ token

      # … and it is not on the page for anyone who arrives later.
      {:ok, _fresh_lv, fresh_html} = live(conn, ~p"/nodes")
      refute fresh_html =~ token
      assert fresh_html =~ "POS-03"
    end

    test "the issued token actually authenticates that node", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/nodes")

      lv |> element("button", "Register new node") |> render_click()

      html =
        lv
        |> form("#node-registration", %{"node" => %{"name" => "POS-03"}})
        |> render_submit()

      token = extract_token(html)

      assert %{name: "POS-03"} = Nodes.fetch_active_node_by_token(token)
    end

    test "reports a duplicate name instead of issuing a token", %{conn: conn} do
      node_fixture(%{name: "POS-03"})

      {:ok, lv, _html} = live(conn, ~p"/nodes")
      lv |> element("button", "Register new node") |> render_click()

      html =
        lv
        |> form("#node-registration", %{"node" => %{"name" => "POS-03"}})
        |> render_submit()

      assert html =~ "has already been taken"
      refute html =~ "is registered"
      assert Nodes.list_nodes() |> length() == 1
    end

    test "validates the name as it is typed", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/nodes")
      lv |> element("button", "Register new node") |> render_click()

      html =
        lv
        |> form("#node-registration", %{"node" => %{"name" => "!!"}})
        |> render_change()

      assert html =~ "may use letters, digits"
    end
  end

  describe "the node list" do
    setup :owner

    test "shows status and last seen", %{conn: conn} do
      {node, _token} = node_with_token(%{name: "POS-01"})
      Nodes.touch_last_seen(node)
      node_fixture(%{name: "POS-02"})

      {:ok, _lv, html} = live(conn, ~p"/nodes")

      assert html =~ "POS-01"
      assert html =~ "POS-02"
      assert html =~ "active"
      assert html =~ "never synced"
    end

    test "says so when no desk is registered", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/nodes")

      assert html =~ "No desks registered"
      assert html =~ "every ingest request is rejected"
    end

    test "revoking flips the status and stops the token working", %{conn: conn} do
      {node, token} = node_with_token(%{name: "POS-01"})

      {:ok, lv, _html} = live(conn, ~p"/nodes")
      html = lv |> element(~s{button[phx-value-id="#{node.id}"]}, "Revoke") |> render_click()

      assert html =~ "revoked"
      refute Nodes.fetch_active_node_by_token(token)
    end

    test "reinstating puts the same token back to work", %{conn: conn} do
      {node, token} = revoked_node_with_token(%{name: "POS-01"})

      {:ok, lv, _html} = live(conn, ~p"/nodes")
      lv |> element(~s{button[phx-value-id="#{node.id}"]}, "Reinstate") |> render_click()

      assert Nodes.fetch_active_node_by_token(token)
    end
  end

  describe "the settings page" do
    test "points an owner at node management", %{conn: conn} do
      conn = log_in_user(conn, staff_user_fixture(%{role: "owner"}))
      node_fixture(%{name: "POS-01"})

      {:ok, _lv, html} = live(conn, ~p"/settings")

      assert html =~ "Manage nodes"
      assert html =~ ~s(href="/nodes")
      assert html =~ "1 desk"
    end

    test "tells a staff user it is not theirs to do", %{conn: conn} do
      conn = log_in_user(conn, staff_user_fixture(%{role: "staff"}))

      {:ok, _lv, html} = live(conn, ~p"/settings")

      assert html =~ "Only an owner can register or revoke"
      refute html =~ "Manage nodes"
    end
  end

  # The token is the only thing on the page inside the issued-token element.
  defp extract_token(html) do
    [_whole, token] =
      Regex.run(~r/id="issued-token-value"[^>]*>\s*([^\s<]+)\s*</, html)

    token
  end
end
