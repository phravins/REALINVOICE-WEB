defmodule RealinvoiceCloud.Billing.CreditNoteLine do
  @moduledoc """
  One line of a credit note.

  Quantities are positive, the same as on an invoice: a credit note is a
  document that *subtracts*, so the sign lives in what the document is, not in
  its numbers. Storing negatives here as well would net the credit back out
  again the moment anything summed it.
  """
  use Ecto.Schema

  import Ecto.Changeset

  schema "credit_note_lines" do
    belongs_to :credit_note, RealinvoiceCloud.Billing.CreditNote
    belongs_to :item, RealinvoiceCloud.Billing.Item
    belongs_to :node, RealinvoiceCloud.Nodes.Node

    field :qty, :decimal
    field :rate, :decimal
    field :tax_rate, :decimal
    field :line_total, :decimal
    field :client_id, :string

    timestamps(type: :utc_datetime)
  end

  @doc """
  Validates a credit note line, on the same terms as an invoice line.
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
