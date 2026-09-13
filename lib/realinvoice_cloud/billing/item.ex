defmodule RealinvoiceCloud.Billing.Item do
  @moduledoc """
  A catalogue entry on a billing desk.

  `item_code` is assigned by the desk, so it is unique per `store_node_id`
  rather than globally — the same code on two desks is two separate items.
  """
  use Ecto.Schema

  import Ecto.Changeset

  schema "items" do
    field :item_code, :string
    field :description, :string
    field :rate, :decimal
    field :tax_rate, :decimal
    field :uom, :string
    field :store_node_id, :string

    timestamps(type: :utc_datetime)
  end

  @doc """
  Validates a catalogue item.

  A rate may be zero (a free or bundled line is legitimate), but never negative,
  and a tax rate has to be a real GST percentage.
  """
  def changeset(item, attrs) do
    item
    |> cast(attrs, [:item_code, :description, :rate, :tax_rate, :uom, :store_node_id])
    |> validate_required([:item_code, :rate, :tax_rate, :store_node_id])
    |> validate_length(:item_code, max: 60)
    |> validate_length(:description, max: 255)
    |> validate_length(:uom, max: 20)
    |> validate_number(:rate, greater_than_or_equal_to: 0)
    |> validate_number(:tax_rate, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> unique_constraint([:store_node_id, :item_code],
      message: "already exists on this billing desk"
    )
  end
end
