defmodule RealinvoiceCloud.Repo.Migrations.CreateSyncNodeClaims do
  use Ecto.Migration

  def change do
    create table(:sync_node_claims) do
      add :store_node_id, :string, null: false

      # SHA-256 of the presented token, never the token itself. This stage
      # accepts any non-empty token, so the digest proves nothing yet — but it
      # means the claim log is not a pile of live credentials the moment real
      # tokens are issued.
      add :token_digest, :string, null: false

      add :batch_count, :integer, null: false, default: 0
      add :row_count, :integer, null: false, default: 0
      add :first_claimed_at, :utc_datetime, null: false
      add :last_seen_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    # One row per (desk, token) pair: a desk rotating its token shows up as a
    # second claim rather than overwriting the history of the first.
    create unique_index(:sync_node_claims, [:store_node_id, :token_digest])
  end
end
