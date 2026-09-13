defmodule RealinvoiceCloud.NodesTest do
  use RealinvoiceCloud.DataCase, async: true

  import RealinvoiceCloud.NodesFixtures

  alias RealinvoiceCloud.Nodes
  alias RealinvoiceCloud.Nodes.Node

  describe "register_node/1" do
    test "returns the node and the one readable copy of its token" do
      assert {:ok, %Node{} = node, token} = Nodes.register_node(%{name: "POS-01"})

      assert node.name == "POS-01"
      assert node.status == "active"
      assert is_nil(node.last_seen_at)
      assert is_binary(token)
    end

    test "never stores the token itself" do
      {:ok, node, token} = Nodes.register_node(%{name: "POS-01"})

      refute node.token_hash == token
      assert node.token_hash == :crypto.hash(:sha256, token)

      # Nor anywhere else on the row: the whole record, read back raw.
      raw = Repo.one!(from n in "nodes", select: map(n, [:name, :token_hash, :status]))
      refute raw.token_hash == token
    end

    test "issues a different token every time" do
      {:ok, _a, token_a} = Nodes.register_node(%{name: "POS-01"})
      {:ok, _b, token_b} = Nodes.register_node(%{name: "POS-02"})

      refute token_a == token_b
    end

    test "issues a token with enough entropy to be unguessable" do
      {:ok, _node, token} = Nodes.register_node(%{name: "POS-01"})

      assert String.starts_with?(token, "rin_")

      secret = String.replace_prefix(token, "rin_", "")
      assert {:ok, bytes} = Base.url_decode64(secret, padding: false)
      assert byte_size(bytes) == 32
    end

    test "requires a name" do
      assert {:error, changeset} = Nodes.register_node(%{})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects a name that is not a plausible desk name" do
      assert {:error, changeset} = Nodes.register_node(%{name: "../../etc/passwd"})
      assert %{name: [_message]} = errors_on(changeset)
    end

    test "rejects a duplicate name" do
      {:ok, _node, _token} = Nodes.register_node(%{name: "POS-01"})

      assert {:error, changeset} = Nodes.register_node(%{name: "POS-01"})
      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end

    test "trims surrounding whitespace from the name" do
      {:ok, node, _token} = Nodes.register_node(%{name: "  POS-01  "})
      assert node.name == "POS-01"
    end

    test "leaves tenant_id unset, since nothing populates it yet" do
      {:ok, node, _token} = Nodes.register_node(%{name: "POS-01"})
      assert is_nil(node.tenant_id)
    end
  end

  describe "fetch_active_node_by_token/1" do
    test "finds the node holding the token" do
      {node, token} = node_with_token()

      assert %Node{id: id} = Nodes.fetch_active_node_by_token(token)
      assert id == node.id
    end

    test "does not find a revoked node" do
      {_node, token} = revoked_node_with_token()

      refute Nodes.fetch_active_node_by_token(token)
    end

    test "finds it again once reinstated" do
      {node, token} = revoked_node_with_token()
      refute Nodes.fetch_active_node_by_token(token)

      {:ok, _node} = Nodes.reinstate_node(node)
      assert Nodes.fetch_active_node_by_token(token)
    end

    test "does not find an unknown token" do
      node_with_token()

      refute Nodes.fetch_active_node_by_token("rin_not-a-real-token")
      refute Nodes.fetch_active_node_by_token("")
      refute Nodes.fetch_active_node_by_token(nil)
    end

    test "does not match a token whose hash it merely resembles" do
      {_node, token} = node_with_token()

      refute Nodes.fetch_active_node_by_token(token <> "x")
      refute Nodes.fetch_active_node_by_token(String.slice(token, 0..-2//1))
    end
  end

  describe "touch_last_seen/1" do
    test "records when the node was last heard from" do
      node = node_fixture()
      assert is_nil(node.last_seen_at)

      touched = Nodes.touch_last_seen(node)

      assert %DateTime{} = touched.last_seen_at
      assert %DateTime{} = Nodes.get_node!(node.id).last_seen_at
    end

    test "does not disturb any other node" do
      node = node_fixture(%{name: "POS-01"})
      other = node_fixture(%{name: "POS-02"})

      Nodes.touch_last_seen(node)

      assert is_nil(Nodes.get_node!(other.id).last_seen_at)
    end
  end

  describe "revoke_node/1 and reinstate_node/1" do
    test "flip the status" do
      node = node_fixture()
      assert node.status == "active"

      {:ok, revoked} = Nodes.revoke_node(node)
      assert revoked.status == "revoked"

      {:ok, reinstated} = Nodes.reinstate_node(revoked)
      assert reinstated.status == "active"
    end

    test "revoking keeps the node and its history" do
      {node, _token} = node_with_token(%{name: "POS-01"})
      Nodes.touch_last_seen(node)

      {:ok, _revoked} = Nodes.revoke_node(node)

      # Revoking withdraws the token's privileges; it does not erase the record
      # of a desk that was in service.
      stored = Nodes.get_node!(node.id)
      assert stored.name == "POS-01"
      assert stored.status == "revoked"
      assert stored.last_seen_at
    end
  end

  describe "list_nodes/0" do
    test "returns nodes newest first" do
      node_fixture(%{name: "POS-01"})
      node_fixture(%{name: "POS-02"})

      assert [%{name: "POS-02"}, %{name: "POS-01"}] = Nodes.list_nodes()
    end
  end

  describe "count_active_nodes/0" do
    test "counts only the nodes that can still sync" do
      node_fixture(%{name: "POS-01"})
      {node, _token} = node_with_token(%{name: "POS-02"})
      {:ok, _revoked} = Nodes.revoke_node(node)

      assert Nodes.count_active_nodes() == 1
    end
  end
end
