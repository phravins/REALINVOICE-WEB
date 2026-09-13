defmodule RealinvoiceCloudWeb.ItemLive.Index do
  @moduledoc """
  The catalogue each billing desk bills against.

  Read-only for the same reason as the customer book: the desk owns its
  catalogue until it is decided otherwise.
  """
  use RealinvoiceCloudWeb, :live_view

  alias RealinvoiceCloud.Billing

  @filter_keys ~w(q node)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Items")
     |> assign(:nodes, Billing.list_store_nodes())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = Map.take(params, @filter_keys)
    items = Billing.list_items(filters)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:filtered?, Enum.any?(filters, fn {_k, v} -> v != "" end))
     |> assign(:items, items)
     |> assign(:count, length(items))}
  end

  @impl true
  def handle_event("filter", params, socket) do
    filters =
      params
      |> Map.take(@filter_keys)
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/items?#{filters}", replace: true)}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/items")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active={:items}
      title="Items"
      subtitle="The catalogue your billing desks bill against"
    >
      <div class="space-y-6">
        <form
          id="item-filters"
          phx-change="filter"
          phx-submit="filter"
          class="flex flex-wrap items-end gap-3"
        >
          <div class="min-w-56 flex-1 space-y-1.5">
            <.label for="filter-q">Search</.label>
            <.input
              id="filter-q"
              type="text"
              name="q"
              value={@filters["q"]}
              placeholder="Item code or description"
              phx-debounce="300"
            />
          </div>

          <div class="space-y-1.5">
            <.label for="filter-node">Node</.label>
            <.select_input id="filter-node" name="node" value={@filters["node"]} prompt="All nodes">
              <option :for={node <- @nodes} value={node} selected={@filters["node"] == node}>
                {node}
              </option>
            </.select_input>
          </div>

          <.button :if={@filtered?} type="button" variant="ghost" phx-click="clear_filters">
            Clear
          </.button>
        </form>

        <p class="text-sm text-muted-foreground">
          {@count} {if @count == 1, do: "item", else: "items"}
        </p>

        <div :if={@count > 0} class="overflow-x-auto">
          <.table>
            <.table_header>
              <.table_row>
                <.table_head>Code</.table_head>
                <.table_head>Description</.table_head>
                <.table_head>UOM</.table_head>
                <.table_head class="text-right">Rate</.table_head>
                <.table_head class="text-right">Tax</.table_head>
                <.table_head>Node</.table_head>
              </.table_row>
            </.table_header>
            <.table_body>
              <.table_row :for={item <- @items}>
                <.table_cell class="font-medium whitespace-nowrap">{item.item_code}</.table_cell>
                <.table_cell>{item.description || "—"}</.table_cell>
                <.table_cell>{item.uom || "—"}</.table_cell>
                <.table_cell class="text-right whitespace-nowrap">{money(item.rate)}</.table_cell>
                <.table_cell class="text-right whitespace-nowrap">
                  {percent(item.tax_rate)}
                </.table_cell>
                <.table_cell>
                  <.badge variant="secondary">{item.store_node_id}</.badge>
                </.table_cell>
              </.table_row>
            </.table_body>
          </.table>
        </div>

        <.empty_state
          :if={@count == 0}
          icon="hero-cube"
          title={if @filtered?, do: "No matching items", else: "No items yet"}
          message={
            if @filtered?,
              do: "No item matches this search.",
              else: "Your catalogue will appear here once your billing desks start syncing."
          }
        />
      </div>
    </Layouts.app>
    """
  end
end
