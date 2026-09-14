defmodule RealinvoiceCloud.Sync do
  @moduledoc """
  Ingest of batches pushed up by a billing desk's sync worker.

  ## The contract

  A batch is a list of rows. Every row carries a `client_id` the desk generated
  and never reuses, a `type`, and a `data` object matching the corresponding
  schema in `RealinvoiceCloud.Billing`:

      %{
        "rows" => [
          %{"client_id" => "…", "type" => "customer", "data" => %{…}},
          %{"client_id" => "…", "type" => "item",     "data" => %{…}},
          %{"client_id" => "…", "type" => "invoice",  "data" => %{…, "lines" => [%{…}]}},
          %{"client_id" => "…", "type" => "invoice_line",
            "invoice_client_id" => "…", "data" => %{…}},
          %{"client_id" => "…", "type" => "credit_note",
            "data" => %{…, "original_invoice_client_id" => "…", "lines" => [%{…}]}},
          %{"client_id" => "…", "type" => "credit_note_line",
            "credit_note_client_id" => "…", "data" => %{…}}
        ]
      }

  Invoice lines may arrive either nested inside their invoice's `lines`, or as
  separate rows naming their invoice with `invoice_client_id`. Both end up in
  the same place, so a desk can send whichever suits its worker. Credit note
  lines work identically, naming their note with `credit_note_client_id`.

  A credit note names the invoice it corrects with `original_invoice_client_id`.
  That invoice must either be in the same batch or already stored; a credit note
  with nothing to credit is rejected rather than stored unlinked, because an
  unlinked credit would silently stop netting off anything.

  An invoice names its customer with `customer_client_id` and each line names
  its item with `item_client_id` — the desk's own identifiers, which this server
  translates to its own primary keys. A desk never sends this server's ids,
  because it has no way to know them.

  ## Rules

    * **Idempotent.** Every row is looked up by `client_id` first. A retried
      batch reports what it already wrote and changes nothing.
    * **Invoices and credit notes are append-only.** One already stored is never
      updated, whatever a later batch says. Customers and items are upserted,
      last write wins.
    * **A row fails on its own.** Each unit of work is its own transaction, so
      one invalid row does not roll back the rest of the batch. That is what
      lets the response say which rows were accepted and which were not.
    * **An invoice is one unit** with its lines: either the invoice and all of
      its lines land, or none of it does.
    * **The desk cannot attribute rows to another desk.** The desk is whichever
      node's token authenticated the request; `store_node_id` is taken from that
      node's name and overwrites anything in the payload. A node cannot claim to
      be a different node than the token it presented.
    * **Client ids are scoped to the node.** Two desks may generate the same
      client id for unrelated rows, so the identity of a synced row is
      (node, client_id) — never the client id alone.

  ## Ordering

  Rows are processed in type order — customers and items, then invoices, then
  standalone invoice lines, then credit notes and their lines — whatever order
  they arrive in, because each stage refers to the ones before it. A desk does
  not have to sort its batch.
  """

  import Ecto.Query, warn: false

  alias RealinvoiceCloud.Billing
  alias RealinvoiceCloud.Nodes.Node

  require Logger

  @row_types ~w(customer item invoice invoice_line credit_note credit_note_line)
  @max_rows 1000

  @doc """
  Processes one batch from an authenticated node, returning a result per row.

  Returns `{:ok, results}` for a well-formed batch — an individual row failing
  validation is an outcome to report, not an error for the batch. A batch that
  is not well formed at all returns `{:error, reason}`.
  """
  def ingest_batch(node, rows)

  def ingest_batch(%Node{}, rows) when not is_list(rows) do
    {:error, "rows must be a list"}
  end

  def ingest_batch(%Node{}, rows) when length(rows) > @max_rows do
    {:error, "a batch may carry at most #{@max_rows} rows"}
  end

  def ingest_batch(%Node{} = node, rows) do
    results =
      rows
      |> Enum.map(&parse_row(&1, node))
      |> process_pass([:customer, :item])
      |> process_pass([:invoice])
      |> process_pass([:invoice_line])
      |> process_pass([:credit_note])
      |> process_pass([:credit_note_line])
      |> Enum.map(&to_result/1)

    {:ok, results}
  end

  ## Parsing

  # Each row becomes a work item carrying either what to do or why it cannot be
  # done, so a malformed row is reported in its own place in the response
  # rather than aborting the batch.
  defp parse_row(row, %Node{} = node) when is_map(row) do
    row = stringify(row)
    client_id = string_value(row, "client_id")
    type = string_value(row, "type")
    data = Map.get(row, "data")

    cond do
      client_id in [nil, ""] ->
        %{type: type, client_id: nil, error: "client_id is required"}

      type not in @row_types ->
        %{
          type: type,
          client_id: client_id,
          error: "type must be one of: #{Enum.join(@row_types, ", ")}"
        }

      not is_map(data) ->
        %{type: type, client_id: client_id, error: "data must be an object"}

      true ->
        %{
          type: String.to_existing_atom(type),
          client_id: client_id,
          invoice_client_id: string_value(row, "invoice_client_id"),
          credit_note_client_id: string_value(row, "credit_note_client_id"),
          node: node,
          data: prepare_data(data, node),
          error: nil
        }
    end
  end

  defp parse_row(_row, _node),
    do: %{type: nil, client_id: nil, error: "each row must be an object"}

  # The authenticated node wins, and foreign keys are never taken from the wire:
  # a desk knows its own client ids, not this server's primary keys, so an
  # incoming `customer_id`, `item_id` or `node_id` can only be a mistake or an
  # attempt to attach a row to someone else's record.
  defp prepare_data(data, %Node{} = node) do
    data
    |> stringify()
    |> Map.drop([
      "customer_id",
      "item_id",
      "invoice_id",
      "credit_note_id",
      "original_invoice_id",
      "node_id",
      "id"
    ])
    |> Map.put("store_node_id", node.name)
    |> Map.put("node_id", node.id)
  end

  ## Processing

  # Each pass sees the results of the passes before it, which is how an invoice
  # line finds out whether its invoice landed.
  defp process_pass(items, types) do
    Enum.map(items, fn item ->
      if is_nil(item[:error]) and item[:type] in types and is_nil(item[:outcome]) do
        process(item, items)
      else
        item
      end
    end)
  end

  defp process(%{type: :customer} = item, _items) do
    case Billing.get_by_client_id(:customer, item.node.id, item.client_id) do
      nil -> put_outcome(item, Billing.upsert_customer(nil, with_client_id(item)), :inserted)
      existing -> put_outcome(item, Billing.upsert_customer(existing, item.data), :updated)
    end
  end

  defp process(%{type: :item} = item, _items) do
    case Billing.get_by_client_id(:item, item.node.id, item.client_id) do
      nil -> put_outcome(item, Billing.upsert_item(nil, with_client_id(item)), :inserted)
      existing -> put_outcome(item, Billing.upsert_item(existing, item.data), :updated)
    end
  end

  defp process(%{type: :invoice} = item, items) do
    case Billing.get_by_client_id(:invoice, item.node.id, item.client_id) do
      # Append-only: an invoice already here is never rewritten, however many
      # times a desk sends it.
      %{} = existing ->
        put_outcome(item, {:ok, existing}, :unchanged)

      nil ->
        attrs =
          item
          |> with_client_id()
          |> Map.put("lines", lines_for(item, items))
          |> resolve_customer(item)

        put_outcome(item, Billing.create_invoice(attrs), :inserted)
    end
  end

  defp process(%{type: :credit_note} = item, items) do
    case Billing.get_by_client_id(:credit_note, item.node.id, item.client_id) do
      # Append-only, for the same reason invoices are.
      %{} = existing ->
        put_outcome(item, {:ok, existing}, :unchanged)

      nil ->
        case resolve_original_invoice(item, items) do
          {:ok, invoice_id} ->
            attrs =
              item
              |> with_client_id()
              |> Map.put("lines", lines_for(item, items, :credit_note_line))
              |> Map.put("original_invoice_id", invoice_id)

            put_outcome(item, Billing.create_credit_note(attrs), :inserted)

          {:error, reason} ->
            %{item | error: reason}
        end
    end
  end

  # A line sent as its own row is applied as part of its parent document, so all
  # that happens here is reporting what became of it.
  defp process(%{type: :invoice_line} = item, items),
    do: process_line(item, items, :invoice, :invoice_line, item.invoice_client_id)

  defp process(%{type: :credit_note_line} = item, items),
    do: process_line(item, items, :credit_note, :credit_note_line, item.credit_note_client_id)

  defp process_line(item, items, parent_type, line_type, parent_client_id) do
    parent_key = "#{parent_type}_client_id"

    parent_item =
      Enum.find(items, &(&1[:type] == parent_type and &1[:client_id] == parent_client_id))

    stored_line =
      parent_client_id && Billing.get_by_client_id(line_type, item.node.id, item.client_id)

    cond do
      is_nil(parent_client_id) ->
        %{item | error: "#{parent_key} is required for #{article(line_type)} #{line_type} row"}

      parent_item ->
        case parent_item[:outcome] do
          {:ok, _parent} ->
            # Report the line's own id, not its parent's — the worker asked
            # about this row.
            case Billing.get_by_client_id(line_type, item.node.id, item.client_id) do
              nil -> %{item | error: "its #{parent_type} was accepted without this line"}
              line -> put_outcome(item, {:ok, line}, parent_item[:action])
            end

          _rejected ->
            %{item | error: "its #{parent_type} was rejected"}
        end

      stored_line ->
        # A retry of a line whose parent landed in an earlier batch.
        put_outcome(item, {:ok, stored_line}, :unchanged)

      true ->
        %{item | error: "no #{parent_type} in this batch or already stored for #{parent_key}"}
    end
  end

  # "an invoice_line", but "a credit_note_line" — the row type is part of the
  # sentence the worker's operator reads, so it should read like one.
  defp article(type) do
    if String.first(to_string(type)) in ~w(a e i o u), do: "an", else: "a"
  end

  # Lines nested inside the document, plus any sent as their own rows naming it.
  defp lines_for(parent_item, items, line_type \\ :invoice_line) do
    parent_key =
      if line_type == :credit_note_line, do: :credit_note_client_id, else: :invoice_client_id

    nested =
      parent_item.data
      |> Map.get("lines", [])
      |> List.wrap()
      |> Enum.map(&stringify/1)

    standalone =
      items
      |> Enum.filter(
        &(&1[:type] == line_type and &1[parent_key] == parent_item.client_id and
            is_nil(&1[:error]))
      )
      |> Enum.map(&Map.put(&1.data, "client_id", &1.client_id))

    Enum.map(nested ++ standalone, &resolve_item(&1, parent_item.node))
  end

  # A credit note has to name an invoice that exists, in this batch or already
  # stored. Storing one unlinked would leave a credit that nets off nothing.
  defp resolve_original_invoice(item, items) do
    case string_value(item.data, "original_invoice_client_id") do
      nil ->
        {:error, "original_invoice_client_id is required for a credit_note row"}

      invoice_client_id ->
        batch_invoice =
          Enum.find(items, &(&1[:type] == :invoice and &1[:client_id] == invoice_client_id))

        stored = Billing.get_by_client_id(:invoice, item.node.id, invoice_client_id)

        cond do
          match?({:ok, _}, batch_invoice[:outcome]) ->
            {:ok, elem(batch_invoice[:outcome], 1).id}

          batch_invoice ->
            {:error, "its original invoice was rejected"}

          stored ->
            {:ok, stored.id}

          true ->
            {:error, "no invoice in this batch or already stored for original_invoice_client_id"}
        end
    end
  end

  # Lines name their item by the desk's client id, resolved within that desk.
  defp resolve_item(line, %Node{} = node) do
    case string_value(line, "item_client_id") do
      nil ->
        line

      item_client_id ->
        case Billing.get_by_client_id(:item, node.id, item_client_id) do
          nil -> line
          item -> Map.put(line, "item_id", item.id)
        end
    end
  end

  # Invoices name their customer by the desk's client id, within that desk.
  defp resolve_customer(attrs, item) do
    case string_value(item.data, "customer_client_id") do
      nil ->
        attrs

      customer_client_id ->
        case Billing.get_by_client_id(:customer, item.node.id, customer_client_id) do
          nil -> attrs
          customer -> Map.put(attrs, "customer_id", customer.id)
        end
    end
  end

  defp with_client_id(item), do: Map.put(item.data, "client_id", item.client_id)

  defp put_outcome(item, outcome, action) do
    item |> Map.put(:outcome, outcome) |> Map.put(:action, action)
  end

  ## Results

  defp to_result(%{error: error} = item) when is_binary(error) do
    %{
      client_id: item[:client_id],
      type: type_string(item[:type]),
      status: "rejected",
      errors: %{base: [error]}
    }
  end

  defp to_result(%{outcome: {:ok, record}} = item) do
    %{
      client_id: item.client_id,
      type: type_string(item.type),
      status: "accepted",
      action: to_string(item.action),
      id: record.id
    }
  end

  defp to_result(%{outcome: {:error, changeset}} = item) do
    %{
      client_id: item.client_id,
      type: type_string(item.type),
      status: "rejected",
      errors: changeset_errors(changeset)
    }
  end

  defp type_string(nil), do: nil
  defp type_string(type), do: to_string(type)

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r/%{(\w+)}/, message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  ## Helpers

  defp string_value(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      nil -> nil
      other -> to_string(other)
    end
  end

  defp string_value(_map, _key), do: nil

  # JSON arrives with string keys; anything built in Elixir may not. Normalise
  # so the changesets always see one shape.
  defp stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify(other), do: other
end
