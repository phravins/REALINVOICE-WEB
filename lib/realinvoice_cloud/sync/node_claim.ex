defmodule RealinvoiceCloud.Sync.NodeClaim do
  @moduledoc """
  A record of which billing desk has presented which API token.

  This stage accepts any non-empty token, so a claim proves nothing about who a
  desk really is — it is a log of what turned up, not an authorisation decision.
  It exists so that when real per-node token issuance arrives there is already a
  picture of which desks are talking to this server and since when.

  Only the SHA-256 of the token is kept. There is no reason to hold the token
  itself, and the habit of not doing so is worth having in place before the
  tokens start meaning something.
  """
  use Ecto.Schema

  import Ecto.Changeset

  schema "sync_node_claims" do
    field :store_node_id, :string
    field :token_digest, :string
    field :batch_count, :integer, default: 0
    field :row_count, :integer, default: 0
    field :first_claimed_at, :utc_datetime
    field :last_seen_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc """
  Hashes a presented token for storage.
  """
  def digest(token) when is_binary(token) do
    :sha256 |> :crypto.hash(token) |> Base.encode16(case: :lower)
  end

  @doc false
  def changeset(claim, attrs) do
    claim
    |> cast(attrs, [
      :store_node_id,
      :token_digest,
      :batch_count,
      :row_count,
      :first_claimed_at,
      :last_seen_at
    ])
    |> validate_required([:store_node_id, :token_digest, :first_claimed_at, :last_seen_at])
    |> unique_constraint([:store_node_id, :token_digest])
  end
end
