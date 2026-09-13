defmodule RealinvoiceCloud.Billing.InvoiceLine do
  @moduledoc """
  One line of an invoice.

  `rate` and `tax_rate` are copied onto the line rather than read from the item,
  because they are what was actually charged: repricing an item later must not
  retrospectively change an invoice that has already been issued.

  `line_total` is the taxable value of the line (quantity × rate, before tax) —
  see `RealinvoiceCloud.Billing.Invoice` for how the totals fit together.
  """
  use Ecto.Schema

  import Ecto.Changeset

  schema "invoice_lines" do
    belongs_to :invoice, RealinvoiceCloud.Billing.Invoice
    belongs_to :item, RealinvoiceCloud.Billing.Item

    field :qty, :decimal
    field :rate, :decimal
    field :tax_rate, :decimal
    field :line_total, :decimal
    belongs_to :node, RealinvoiceCloud.Nodes.Node
    field :client_id, :string

    timestamps(type: :utc_datetime)
  end

  @doc """
  Validates an invoice line.

  A line with a zero or negative quantity is not a line, so that is rejected
  outright; a zero rate is allowed for a free or bundled item.
  """
  def changeset(line, attrs) do
    line
    |> cast(attrs, [:item_id, :qty, :rate, :tax_rate, :line_total, :client_id, :node_id])
    |> validate_required([:item_id, :qty, :rate, :tax_rate, :line_total])
    |> validate_number(:qty, greater_than: 0)
    |> validate_number(:rate, greater_than_or_equal_to: 0)
    |> validate_number(:tax_rate, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:line_total, greater_than_or_equal_to: 0)
    |> assoc_constraint(:item)
    |> unique_constraint([:node_id, :client_id])
  end
end
