defmodule RealinvoiceCloudWeb.SyncIngestController do
  @moduledoc """
  The endpoint a billing desk's sync worker pushes batches to.

  See `RealinvoiceCloud.Sync` for the payload contract and the ingest rules.
  """
  use RealinvoiceCloudWeb, :controller

  alias RealinvoiceCloud.Sync

  require Logger

  @doc """
  Ingests one batch.

  The desk is identified by its token, not by anything in the payload.

  Responds `200` with a result for every row, even when some rows were
  rejected: the worker needs to know precisely which rows to retry or report,
  and a batch-level failure would tell it nothing. Only a batch that cannot be
  read at all is a `422`.
  """
  def create(conn, params) do
    node = conn.assigns.sync_node
    rows = params["rows"] || []

    warn_on_claimed_node(params["store_node_id"], node)

    case Sync.ingest_batch(node, rows) do
      {:ok, results} ->
        conn
        |> put_status(:ok)
        |> json(%{
          batch: %{
            store_node_id: node.name,
            received: length(results),
            accepted: Enum.count(results, &(&1.status == "accepted")),
            rejected: Enum.count(results, &(&1.status == "rejected"))
          },
          results: results
        })

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_batch", detail: reason})
    end
  end

  # A desk sending a store_node_id that disagrees with its token is almost
  # certainly misconfigured. The token still decides, but saying so beats
  # leaving someone to wonder why their rows are filed under another name.
  defp warn_on_claimed_node(nil, _node), do: :ok
  defp warn_on_claimed_node(claimed, %{name: name}) when claimed == name, do: :ok

  defp warn_on_claimed_node(claimed, node) do
    Logger.info(
      "node #{node.name} sent store_node_id #{inspect(claimed)}; using the authenticated node"
    )
  end
end
