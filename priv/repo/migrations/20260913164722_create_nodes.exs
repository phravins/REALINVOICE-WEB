defmodule RealinvoiceCloud.Repo.Migrations.CreateNodes do
  use Ecto.Migration

  def change do
    create table(:nodes) do
      # What the desk calls itself, e.g. "POS-01". This is the store_node_id
      # stamped on everything the desk sends — derived from the node, never
      # from the payload.
      add :name, :string, null: false

      # SHA-256 of the issued token. The token itself is shown once, at
      # registration, and is not recoverable from here.
      add :token_hash, :binary, null: false

      add :status, :string, null: false, default: "active"
      add :last_seen_at, :utc_datetime

      # Reserved for multi-tenancy. Unused today — this server holds one
      # OSWORKS client — but adding the column to a live sync table later means
      # backfilling every row under load, and adding it now costs nothing.
      add :tenant_id, :string

      timestamps(type: :utc_datetime)
    end

    # The lookup ingest does on every request: one indexed row, no scanning.
    create unique_index(:nodes, [:token_hash])

    # Becomes [:tenant_id, :name] when tenancy arrives; until then a desk name
    # is unique across the server.
    create unique_index(:nodes, [:name])
    create index(:nodes, [:tenant_id])
    create index(:nodes, [:status])
  end
end
