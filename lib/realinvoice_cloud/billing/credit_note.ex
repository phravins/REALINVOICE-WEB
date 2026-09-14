defmodule RealinvoiceCloud.Billing.CreditNote do
  @moduledoc """
  A credit note issued at a billing desk against an invoice it has already
  issued.

  ## Signs

  Every figure on a credit note is stored **positive**, exactly as the desk sent
  it, the same way an invoice's are. A credit note subtracts because of what it
  is, not because its numbers are negative — so anything that nets credits off
  revenue does so by subtracting these totals, and a sum over credit notes reads
  as "how much was credited", not as a negative.

  ## Dates

  A credit note carries its own date, which is the date it reduces. A note
  issued today against last month's invoice reduces today's takings, not last
  month's — the same way the desk's own books treat it, and the reason the
  figures are not restated behind anyone's back.

  ## Numbering

  `credit_note_no` is unique per `store_node_id`, not globally: each desk runs
  its own sequence, just as it does for invoices.

  As with invoices, the totals here are the desk's and are stored exactly as
  sent. Nothing in the back office recomputes them.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @amount_fields [:subtotal, :cgst, :sgst, :igst, :grand_total]

  schema "credit_notes" do
    field :credit_note_no, :string
    field :date, :date
    field :reason, :string

    belongs_to :original_invoice, RealinvoiceCloud.Billing.Invoice
    belongs_to :node, RealinvoiceCloud.Nodes.Node

    field :subtotal, :decimal
    field :cgst, :decimal
    field :sgst, :decimal
    field :igst, :decimal
    field :grand_total, :decimal

    field :store_node_id, :string
    field :created_by, :string
    field :client_id, :string

    has_many :lines, RealinvoiceCloud.Billing.CreditNoteLine, on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @doc """
  Validates a credit note and its lines.
  """
  def changeset(credit_note, attrs) do
    credit_note
    |> cast(attrs, [
      :credit_note_no,
      :date,
      :reason,
      :original_invoice_id,
      :store_node_id,
      :created_by,
      :client_id,
      :node_id | @amount_fields
    ])
    |> cast_assoc(:lines, required: true)
    |> validate_required([
      :credit_note_no,
      :date,
      :original_invoice_id,
      :store_node_id | @amount_fields
    ])
    |> validate_length(:credit_note_no, max: 60)
    |> validate_length(:reason, max: 255)
    |> validate_length(:created_by, max: 120)
    |> validate_amounts()
    |> validate_single_tax_regime()
    |> assoc_constraint(:original_invoice)
    |> unique_constraint([:store_node_id, :credit_note_no],
      message: "already exists for this billing desk"
    )
    |> unique_constraint([:node_id, :client_id])
  end

  defp validate_amounts(changeset) do
    Enum.reduce(@amount_fields, changeset, fn field, acc ->
      validate_number(acc, field, greater_than_or_equal_to: 0)
    end)
  end

  # Same rule as an invoice: a sale is intra-state or inter-state, never both,
  # and a credit note reverses whichever applied.
  defp validate_single_tax_regime(changeset) do
    igst = get_field(changeset, :igst) || Decimal.new(0)
    cgst = get_field(changeset, :cgst) || Decimal.new(0)
    sgst = get_field(changeset, :sgst) || Decimal.new(0)

    if Decimal.gt?(igst, 0) and (Decimal.gt?(cgst, 0) or Decimal.gt?(sgst, 0)) do
      add_error(changeset, :igst, "cannot be charged alongside CGST or SGST")
    else
      changeset
    end
  end
end
