defmodule RealinvoiceCloud.Repo.Migrations.CreateCustomers do
  use Ecto.Migration

  def change do
    create table(:customers) do
      add :name, :string, null: false
      add :gstin, :string
      add :place_of_supply, :string
      add :mobile, :string

      # Which physical billing desk this record came from. Every synced row
      # carries it, so the cloud can always attribute data to a desk.
      add :store_node_id, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:customers, [:store_node_id])
    create index(:customers, [:name])
    create index(:customers, [:gstin])
  end
end
