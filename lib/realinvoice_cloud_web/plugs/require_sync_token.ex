defmodule RealinvoiceCloudWeb.Plugs.RequireSyncToken do
  @moduledoc """
  Authenticates a billing desk by the API token it presents.

  The token is hashed and looked up against **active nodes only**. Anything that
  does not resolve to one — a made-up token, a token for a revoked node, no
  token at all — is a `401`, and the request never reaches the controller.

  On success the node is assigned to the connection as `:sync_node` and its
  `last_seen_at` is updated, which is the signal the desks' health display is
  built on.

  The token is read from `authorization: Bearer <token>`, or from
  `x-api-token: <token>` for workers that find that easier.
  """
  import Plug.Conn

  alias RealinvoiceCloud.Nodes

  require Logger

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    with {:ok, token} <- extract_token(conn),
         %{} = node <- Nodes.fetch_active_node_by_token(token) do
      conn
      |> assign(:sync_node, Nodes.touch_last_seen(node))
      |> assign(:store_node_id, node.name)
    else
      _unauthenticated ->
        # Deliberately one message for every failure: telling a caller whether a
        # token was unknown, revoked or merely absent hands them a probe.
        Logger.info("rejected sync request from #{peer(conn)}: no active node for token")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          401,
          Jason.encode!(%{
            error: "unauthorized",
            detail:
              "present an active billing desk's sync token as `Authorization: Bearer <token>` or `X-Api-Token: <token>`"
          })
        )
        |> halt()
    end
  end

  defp extract_token(conn) do
    bearer =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token | _rest] -> String.trim(token)
        ["bearer " <> token | _rest] -> String.trim(token)
        _other -> ""
      end

    plain =
      case get_req_header(conn, "x-api-token") do
        [token | _rest] -> String.trim(token)
        [] -> ""
      end

    case {bearer, plain} do
      {"", ""} -> :error
      {"", token} -> {:ok, token}
      {token, _plain} -> {:ok, token}
    end
  end

  defp peer(conn) do
    case conn.remote_ip do
      nil -> "unknown"
      ip -> ip |> :inet.ntoa() |> to_string()
    end
  end
end
