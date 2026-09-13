defmodule RealinvoiceCloud.Repo.Migrations.DropSyncNodeClaims do
  use Ecto.Migration

  # Superseded by the nodes table. The claim log existed only because there was
  # nothing to authenticate against; now a node is a real record and
  # nodes.last_seen_at is the live signal it was standing in for.
  def up do
    drop table(:sync_node_claims)
  end

  def down do
    create table(:sync_node_claims) do
      add :store_node_id, :string, null: false
      add :token_digest, :string, null: false
      add :batch_count, :integer, null: false, default: 0
      add :row_count, :integer, null: false, default: 0
      add :first_claimed_at, :utc_datetime, null: false
      add :last_seen_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:sync_node_claims, [:store_node_id, :token_digest])
  end
end
