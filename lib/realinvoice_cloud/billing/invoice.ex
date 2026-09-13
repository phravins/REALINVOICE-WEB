defmodule RealinvoiceCloud.Billing.Invoice do
  @moduledoc """
  An invoice issued at a billing desk.

  ## How the totals fit together

    * each line's `line_total` is its taxable value (quantity × rate, pre-tax)
    * `subtotal` is the sum of the line totals
    * `cgst` + `sgst` carry the tax on an intra-state sale, `igst` on an
      inter-state one — one pair or the other, never both
    * `grand_total` is `subtotal` plus whichever tax applies

  **The cloud does not compute any of this.** The desk is the authority on what
  it charged a customer, so these figures are stored exactly as sent. The
  validations here are integrity checks (present, non-negative, not both tax
  regimes at once), not a reimplementation of the desk's GST arithmetic. Once
  the ingest API exists this is the natural place to *cross-check* the desk's
  maths and flag disagreements — but flagging is not recomputing, and neither
  belongs in this stage.

  `invoice_no` is unique per `store_node_id`, not globally: every desk numbers
  its own invoices and they all start again at `RI-2026-0001`.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @amount_fields [:subtotal, :cgst, :sgst, :igst, :grand_total]

  schema "invoices" do
    field :invoice_no, :string
    field :date, :date

    belongs_to :customer, RealinvoiceCloud.Billing.Customer

    field :subtotal, :decimal
    field :cgst, :decimal
    field :sgst, :decimal
    field :igst, :decimal
    field :grand_total, :decimal

    field :payment_type, :string
    field :store_node_id, :string

    # A label sent by the desk (the cashier's name or local id). The cloud has
    # no local user accounts to resolve it against, so it is stored verbatim.
    field :created_by, :string
    belongs_to :node, RealinvoiceCloud.Nodes.Node
    field :client_id, :string

    has_many :lines, RealinvoiceCloud.Billing.InvoiceLine, on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @doc """
  Validates an invoice and its lines.

  Pass `lines` in `attrs` to insert an invoice with its lines in one
  transaction; the lines are validated by
  `RealinvoiceCloud.Billing.InvoiceLine.changeset/2`.
  """
  def changeset(invoice, attrs) do
    invoice
    |> cast(attrs, [
      :invoice_no,
      :date,
      :customer_id,
      :payment_type,
      :store_node_id,
      :created_by,
      :client_id,
      :node_id | @amount_fields
    ])
    |> cast_assoc(:lines, required: true)
    |> validate_required([:invoice_no, :date, :payment_type, :store_node_id | @amount_fields])
    |> validate_length(:invoice_no, max: 60)
    |> validate_length(:payment_type, max: 40)
    |> validate_length(:created_by, max: 120)
    |> validate_amounts()
    |> validate_single_tax_regime()
    |> assoc_constraint(:customer)
    |> unique_constraint([:store_node_id, :invoice_no],
      message: "already exists for this billing desk"
    )
    |> unique_constraint([:node_id, :client_id])
  end

  defp validate_amounts(changeset) do
    Enum.reduce(@amount_fields, changeset, fn field, acc ->
      validate_number(acc, field, greater_than_or_equal_to: 0)
    end)
  end

  # A sale is either intra-state (CGST + SGST) or inter-state (IGST). Both at
  # once means the desk sent something incoherent, and storing it would quietly
  # corrupt every tax report built on top of it later.
  defp validate_single_tax_regime(changeset) do
    igst = get_field(changeset, :igst) || Decimal.new(0)
    cgst = get_field(changeset, :cgst) || Decimal.new(0)
    sgst = get_field(changeset, :sgst) || Decimal.new(0)

    intra_state? = Decimal.gt?(cgst, 0) or Decimal.gt?(sgst, 0)

    if Decimal.gt?(igst, 0) and intra_state? do
      add_error(changeset, :igst, "cannot be charged alongside CGST or SGST")
    else
      changeset
    end
  end
end
