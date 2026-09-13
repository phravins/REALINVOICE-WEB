defmodule RealinvoiceCloud.Nodes do
  @moduledoc """
  Registering billing desks and authenticating the tokens they present.

  A node is registered from the back office, which is the only moment its token
  exists in readable form. From then on the server holds a SHA-256 of it and can
  do exactly one thing with it: recognise the same token coming back.
  """

  import Ecto.Query, warn: false

  alias RealinvoiceCloud.Nodes.Node
  alias RealinvoiceCloud.Repo

  @rand_size 32
  @hash_algorithm :sha256
  @token_prefix "rin_"

  @doc """
  Registers a node and returns the one and only copy of its token.

  Returns `{:ok, node, token}`. The token is not stored and cannot be recovered
  — if the operator loses it, the node needs a new one.
  """
  def register_node(attrs) do
    token = generate_token()

    %Node{}
    |> Node.registration_changeset(attrs)
    |> Node.put_token_hash(hash_token(token))
    |> Repo.insert()
    |> case do
      {:ok, node} -> {:ok, node, token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Returns a changeset for the registration form.
  """
  def change_node_registration(node \\ %Node{}, attrs \\ %{}) do
    Node.registration_changeset(node, attrs)
  end

  @doc """
  Finds the active node holding this token, or `nil`.

  A revoked node does not match, so revoking takes effect on the desk's very
  next request rather than whenever something happens to reload.
  """
  def fetch_active_node_by_token(token) when is_binary(token) and token != "" do
    Repo.one(
      from n in Node,
        where: n.token_hash == ^hash_token(token) and n.status == "active"
    )
  end

  def fetch_active_node_by_token(_token), do: nil

  @doc """
  Records that a node just made a successful request.
  """
  def touch_last_seen(%Node{} = node) do
    now = DateTime.utc_now(:second)

    {1, _} =
      Repo.update_all(
        from(n in Node, where: n.id == ^node.id),
        set: [last_seen_at: now, updated_at: now]
      )

    %{node | last_seen_at: now}
  end

  @doc """
  Lists nodes, most recently registered first.
  """
  def list_nodes do
    Repo.all(from n in Node, order_by: [desc: n.inserted_at, desc: n.id])
  end

  @doc """
  Fetches one node, raising if it does not exist.
  """
  def get_node!(id), do: Repo.get!(Node, id)

  @doc """
  Revokes a node. Its token stops working on the next request.
  """
  def revoke_node(%Node{} = node), do: node |> Node.status_changeset("revoked") |> Repo.update()

  @doc """
  Puts a revoked node back into service with the token it already has.
  """
  def reinstate_node(%Node{} = node), do: node |> Node.status_changeset("active") |> Repo.update()

  @doc """
  How many nodes are currently able to sync.
  """
  def count_active_nodes, do: Repo.aggregate(from(n in Node, where: n.status == "active"), :count)

  # A recognisable prefix makes a leaked token greppable in logs and scanning
  # tools, and tells an operator what they are looking at.
  defp generate_token do
    @token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(@rand_size), padding: false)
  end

  @doc false
  def hash_token(token), do: :crypto.hash(@hash_algorithm, token)
end
