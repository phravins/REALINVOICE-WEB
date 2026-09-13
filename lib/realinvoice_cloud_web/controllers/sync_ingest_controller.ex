defmodule RealinvoiceCloudWeb.SyncIngestController do
  @moduledoc """
  The endpoint a billing desk's sync worker pushes batches to.

  See `RealinvoiceCloud.Sync` for the payload contract and the ingest rules.
  """
  use RealinvoiceCloudWeb, :controller

  alias RealinvoiceCloud.Sync

  @doc """
  Ingests one batch.

  Responds `200` with a result for every row, even when some rows were
  rejected: the worker needs to know precisely which rows to retry or report,
  and a batch-level failure would tell it nothing. Only a batch that cannot be
  read at all is a `422`.
  """
  def create(conn, params) do
    store_node_id = params["store_node_id"]
    rows = params["rows"] || []

    case Sync.ingest_batch(store_node_id, rows) do
      {:ok, results} ->
        # Bookkeeping only, and never allowed to fail the batch.
        Sync.record_claim(store_node_id, conn.assigns.sync_token, length(rows))

        conn
        |> put_status(:ok)
        |> json(%{
          batch: %{
            store_node_id: store_node_id,
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
end
