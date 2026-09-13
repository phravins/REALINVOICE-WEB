defmodule RealinvoiceCloud.Repo.Migrations.CreateItems do
  use Ecto.Migration

  def change do
    create table(:items) do
      add :item_code, :string, null: false
      add :description, :string
      add :rate, :decimal, precision: 14, scale: 2, null: false
      add :tax_rate, :decimal, precision: 5, scale: 2, null: false
      add :uom, :string
      add :store_node_id, :string, null: false

      timestamps(type: :utc_datetime)
    end

    # Item codes are assigned per desk, so they are only unique within a desk —
    # the same code on two desks is two different catalogue entries. This is
    # also the natural key an ingest upsert will match on.
    create unique_index(:items, [:store_node_id, :item_code])
  end
end
