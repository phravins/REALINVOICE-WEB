defmodule RealinvoiceCloud.NodesFixtures do
  @moduledoc """
  Test helpers for registering billing desks via `RealinvoiceCloud.Nodes`.
  """

  alias RealinvoiceCloud.Nodes

  @doc """
  Registers a node and returns `{node, token}` — the only time the token exists.
  """
  def node_with_token(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{name: "POS-#{System.unique_integer([:positive])}"})
    {:ok, node, token} = Nodes.register_node(attrs)
    {node, token}
  end

  @doc """
  Registers a node and returns just the node.
  """
  def node_fixture(attrs \\ %{}) do
    {node, _token} = node_with_token(attrs)
    node
  end

  @doc """
  Registers a node, revokes it, and returns `{node, token}`.
  """
  def revoked_node_with_token(attrs \\ %{}) do
    {node, token} = node_with_token(attrs)
    {:ok, node} = Nodes.revoke_node(node)
    {node, token}
  end
end
