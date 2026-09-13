defmodule RealinvoiceCloudWeb.SyncLiveUpdateTest do
  @moduledoc """
  The whole pipe, end to end: an HTTP batch arrives on the ingest endpoint and
  the screens a signed-in admin is already looking at change by themselves.

  Not async — the LiveView processes need to share this test's database
  connection, which only shared sandbox mode allows.
  """
  use RealinvoiceCloudWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import RealinvoiceCloud.AccountsFixtures

  @token "desk-token-abc"

  setup %{conn: conn} do
    %{conn: log_in_user(conn, user_fixture())}
  end

  defp batch(overrides \\ %{}) do
    Map.merge(
      %{
        "store_node_id" => "POS-07",
        "rows" => [
          %{
            "client_id" => "item-1",
            "type" => "item",
            "data" => %{
              "item_code" => "SW-CORE-48P",
              "description" => "48-port Core Switch",
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
              "subtotal" => "2000.00",
              "cgst" => "180.00",
              "sgst" => "180.00",
              "igst" => "0.00",
              "grand_total" => "2360.00",
              "payment_type" => "UPI",
              "created_by" => "Sync worker",
              "lines" => [
                %{
                  "item_client_id" => "item-1",
                  "qty" => "2",
                  "rate" => "1000.00",
                  "tax_rate" => "18.00",
                  "line_total" => "2000.00",
                  "client_id" => "line-1"
                }
              ]
            }
          }
        ]
      },
      overrides
    )
  end

  # A separate connection, the way the desk's worker would arrive.
  defp sync_post(payload) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> @token)
    |> post(~p"/api/sync/ingest", payload)
  end

  test "a synced invoice appears in the list without a reload", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/invoices")

    refute html =~ "RI-SYNCED-0001"
    assert html =~ "No invoices yet"

    assert json_response(sync_post(batch()), 200)["batch"]["rejected"] == 0

    html = render(lv)
    assert html =~ "RI-SYNCED-0001"
    assert html =~ "₹2,360.00"
    assert html =~ "1 invoice"
    # The desk that has just started reporting becomes selectable straight away.
    assert has_element?(lv, ~s{#filter-node option[value="POS-07"]})
  end

  test "the dashboard's figures move without a reload", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/")

    assert html =~ "No data yet"

    sync_post(batch())

    html = render(lv)
    refute html =~ "No data yet"
    assert html =~ "Revenue today"
    assert html =~ "₹2,360.00"
    assert html =~ "POS-07"
  end

  test "a synced invoice that does not match the open filter is not shown", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/invoices?node=POS-99")

    sync_post(batch())

    refute render(lv) =~ "RI-SYNCED-0001"
  end

  test "a retried batch does not add the invoice to the list twice", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/invoices")

    sync_post(batch())
    sync_post(batch())

    html = render(lv)
    assert html =~ "1 invoice"

    occurrences = html |> String.split("RI-SYNCED-0001") |> length() |> Kernel.-(1)
    assert occurrences == 1
  end

  test "a rejected invoice changes nothing on screen", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/invoices")

    broken =
      batch()
      |> Map.update!("rows", fn rows ->
        Enum.map(rows, fn
          %{"client_id" => "inv-1"} = row -> put_in(row, ["data", "grand_total"], "-1.00")
          row -> row
        end)
      end)

    assert json_response(sync_post(broken), 200)["batch"]["rejected"] == 1

    html = render(lv)
    refute html =~ "RI-SYNCED-0001"
    assert html =~ "No invoices yet"
  end
end
