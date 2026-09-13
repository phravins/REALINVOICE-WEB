defmodule RealinvoiceCloudWeb.Plugs.RequireSyncToken do
  @moduledoc """
  Requires a sync API token on the request, and nothing more.

  **This is not authentication.** Any non-empty token is accepted; the token is
  not checked against anything, because nothing issues tokens yet. All it buys
  is that a desk has to be configured deliberately to reach the endpoint, and
  that the server can record which desk claimed which token.

  Real per-node issuance, rotation and revocation — and the multi-tenant scoping
  that makes one desk's token unable to write another tenant's data — are the
  hardening stage. Until then, treat this endpoint as open to anyone who can
  reach it on the network and deploy it accordingly.

  The token is read from `authorization: Bearer <token>`, or from
  `x-api-token: <token>` for workers that find that easier.
  """
  import Plug.Conn

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    case extract_token(conn) do
      {:ok, token} ->
        assign(conn, :sync_token, token)

      :error ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          401,
          Jason.encode!(%{
            error: "unauthorized",
            detail:
              "send the desk's sync token as `Authorization: Bearer <token>` or `X-Api-Token: <token>`"
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
end
