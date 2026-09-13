defmodule RealinvoiceCloudWeb.CustomerLive.Index do
  @moduledoc """
  The customer book, as recorded by the billing desks.

  Read-only: whether the cloud or the desk owns editing a customer record is an
  open question, so there is no create or edit UI here yet.
  """
  use RealinvoiceCloudWeb, :live_view

  alias RealinvoiceCloud.Billing

  @filter_keys ~w(q node)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Customers")
     |> assign(:nodes, Billing.list_store_nodes())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = Map.take(params, @filter_keys)
    customers = Billing.list_customers(filters)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:filtered?, Enum.any?(filters, fn {_k, v} -> v != "" end))
     |> assign(:customers, customers)
     |> assign(:count, length(customers))}
  end

  @impl true
  def handle_event("filter", params, socket) do
    filters =
      params
      |> Map.take(@filter_keys)
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/customers?#{filters}", replace: true)}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/customers")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active={:customers}
      title="Customers"
      subtitle="Customer records synced up from your billing desks"
    >
      <div class="space-y-6">
        <form
          id="customer-filters"
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
              placeholder="Name, GSTIN or mobile"
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
          {@count} {if @count == 1, do: "customer", else: "customers"}
        </p>

        <div :if={@count > 0} class="overflow-x-auto">
          <.table>
            <.table_header>
              <.table_row>
                <.table_head>Name</.table_head>
                <.table_head>GSTIN</.table_head>
                <.table_head>Place of supply</.table_head>
                <.table_head>Mobile</.table_head>
                <.table_head>Node</.table_head>
              </.table_row>
            </.table_header>
            <.table_body>
              <.table_row :for={customer <- @customers}>
                <.table_cell class="font-medium">{customer.name}</.table_cell>
                <.table_cell class="whitespace-nowrap">{customer.gstin || "—"}</.table_cell>
                <.table_cell>{customer.place_of_supply || "—"}</.table_cell>
                <.table_cell class="whitespace-nowrap">{customer.mobile || "—"}</.table_cell>
                <.table_cell>
                  <.badge variant="secondary">{customer.store_node_id}</.badge>
                </.table_cell>
              </.table_row>
            </.table_body>
          </.table>
        </div>

        <.empty_state
          :if={@count == 0}
          icon="hero-users"
          title={if @filtered?, do: "No matching customers", else: "No customers yet"}
          message={
            if @filtered?,
              do: "No customer matches this search.",
              else: "Customers will appear here once your billing desks start syncing."
          }
        />
      </div>
    </Layouts.app>
    """
  end
end
