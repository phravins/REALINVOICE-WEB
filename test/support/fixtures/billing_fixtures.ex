defmodule RealinvoiceCloud.BillingFixtures do
  @moduledoc """
  Test helpers for creating billing records via `RealinvoiceCloud.Billing`.
  """

  alias RealinvoiceCloud.Billing

  def customer_fixture(attrs \\ %{}) do
    attrs
    |> Enum.into(%{
      name: "Vaanavil Systems Pvt Ltd",
      gstin: "33AABCV1234M1Z7",
      place_of_supply: "Tamil Nadu",
      mobile: "+91 98400 11223",
      store_node_id: "POS-01"
    })
    |> Billing.create_customer!()
  end

  def item_fixture(attrs \\ %{}) do
    attrs
    |> Enum.into(%{
      item_code: "RK-42U-PRO-#{System.unique_integer([:positive])}",
      description: "42U Server Rack Pro",
      rate: "48500.00",
      tax_rate: "18.00",
      uom: "Nos",
      store_node_id: "POS-01"
    })
    |> Billing.create_item!()
  end

  @doc """
  An invoice with a single line, defaulting to an intra-state sale.

  Pass `:lines` to control the lines, or any invoice field to override it; an
  item and customer are created as needed.
  """
  def invoice_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    node = Map.get(attrs, :store_node_id, "POS-01")

    lines =
      Map.get_lazy(attrs, :lines, fn ->
        item = item_fixture(%{store_node_id: node})

        [
          %{
            item_id: item.id,
            qty: "2",
            rate: item.rate,
            tax_rate: item.tax_rate,
            line_total: Decimal.mult(Decimal.new("2"), item.rate)
          }
        ]
      end)

    subtotal =
      Enum.reduce(lines, Decimal.new("0.00"), fn line, acc ->
        Decimal.add(acc, Decimal.new(to_string(line.line_total)))
      end)

    tax =
      Enum.reduce(lines, Decimal.new("0.00"), fn line, acc ->
        line.line_total
        |> to_string()
        |> Decimal.new()
        |> Decimal.mult(Decimal.new(to_string(line.tax_rate)))
        |> Decimal.div(100)
        |> Decimal.round(2)
        |> Decimal.add(acc)
      end)

    half = Decimal.round(Decimal.div(tax, 2), 2)

    defaults = %{
      invoice_no: "RI-2026-#{System.unique_integer([:positive])}",
      date: Date.utc_today(),
      customer_id: nil,
      subtotal: subtotal,
      cgst: half,
      sgst: Decimal.sub(tax, half),
      igst: "0.00",
      grand_total: Decimal.add(subtotal, tax),
      payment_type: "Cash",
      store_node_id: node,
      created_by: "Anitha R (till-1)",
      lines: lines
    }

    {:ok, invoice} = Billing.create_invoice(Map.merge(defaults, attrs))
    invoice
  end
end
