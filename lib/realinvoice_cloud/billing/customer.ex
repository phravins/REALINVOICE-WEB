defmodule RealinvoiceCloud.Billing.Customer do
  @moduledoc """
  A customer as recorded on a billing desk.

  Customers are per-desk records: the same walk-in customer billed at two desks
  arrives here as two rows, each carrying the `store_node_id` it came from. The
  cloud does not try to merge them — deciding when two desk records are the same
  customer is a reconciliation question, not a storage one.
  """
  use Ecto.Schema

  import Ecto.Changeset

  # 2 digit state code, 5 letter PAN prefix, 4 digits, 1 letter, 1 entity digit
  # or letter, a literal Z, then a checksum character.
  @gstin_format ~r/^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$/

  schema "customers" do
    field :name, :string
    field :gstin, :string
    field :place_of_supply, :string
    field :mobile, :string
    field :store_node_id, :string

    # Identity of a synced row: the desk it came from, plus the id that desk
    # generated for it. Unique together — see the migration.
    belongs_to :node, RealinvoiceCloud.Nodes.Node
    field :client_id, :string

    has_many :invoices, RealinvoiceCloud.Billing.Invoice

    timestamps(type: :utc_datetime)
  end

  @doc """
  Validates a customer record.

  Mirrors the validation the desktop app's core crate applies before a customer
  can be saved, so a row that would be rejected there is rejected here too.
  """
  def changeset(customer, attrs) do
    customer
    |> cast(attrs, [
      :name,
      :gstin,
      :place_of_supply,
      :mobile,
      :store_node_id,
      :client_id,
      :node_id
    ])
    |> update_change(:gstin, &normalise_gstin/1)
    |> validate_required([:name, :store_node_id])
    |> validate_length(:name, max: 160)
    |> validate_length(:place_of_supply, max: 80)
    |> validate_length(:mobile, max: 20)
    |> validate_format(:gstin, @gstin_format, message: "is not a valid GSTIN")
    |> unique_constraint([:node_id, :client_id])
  end

  defp normalise_gstin(nil), do: nil
  defp normalise_gstin(gstin), do: gstin |> String.trim() |> String.upcase()
end
