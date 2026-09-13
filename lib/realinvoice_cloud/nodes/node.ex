defmodule RealinvoiceCloud.Nodes.Node do
  @moduledoc """
  A billing desk entitled to push data to this server.

  A node holds the SHA-256 of its API token, never the token. The token is
  generated at registration, shown to the operator once, and is not recoverable
  afterwards — losing it means issuing a new one.

  ## Why SHA-256 and not bcrypt

  Passwords are hashed with bcrypt because they are low-entropy and guessable,
  and the cost is there to make guessing expensive. An API token is 32 bytes
  straight from the CSPRNG; there is nothing to guess. More practically, bcrypt
  salts every hash, so a stored bcrypt hash cannot be looked up — authenticating
  a request would mean running bcrypt against every active node in turn. SHA-256
  makes it a single indexed row read, which is exactly what this application's
  own `RealinvoiceCloud.Accounts.UserToken` does with session and magic-link
  tokens.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(active revoked)

  @doc "The statuses a node can hold."
  def statuses, do: @statuses

  schema "nodes" do
    field :name, :string
    field :token_hash, :binary, redact: true
    field :status, :string, default: "active"
    field :last_seen_at, :utc_datetime

    # Reserved for multi-tenancy; nothing reads it yet.
    field :tenant_id, :string

    timestamps(type: :utc_datetime)
  end

  @doc """
  Validates a node being registered.

  The name is what gets stamped on every row the desk sends, so it is held to
  the same shape the rest of the system expects of a `store_node_id`.
  """
  def registration_changeset(node, attrs) do
    node
    |> cast(attrs, [:name, :tenant_id])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 2, max: 60)
    |> validate_format(:name, ~r/^[A-Za-z0-9][A-Za-z0-9 _-]*$/,
      message: "may use letters, digits, spaces, hyphens and underscores"
    )
    |> unique_constraint(:name)
  end

  @doc """
  Sets the token hash on a node being registered.
  """
  def put_token_hash(changeset, token_hash) do
    put_change(changeset, :token_hash, token_hash)
  end

  @doc """
  Flips a node's status.
  """
  def status_changeset(node, status) when status in @statuses do
    node
    |> change(status: status)
    |> validate_inclusion(:status, @statuses)
  end

  @doc """
  Whether this node may currently push data.
  """
  def active?(%__MODULE__{status: "active"}), do: true
  def active?(%__MODULE__{}), do: false
end
