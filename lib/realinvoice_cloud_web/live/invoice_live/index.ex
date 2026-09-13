defmodule RealinvoiceCloudWeb.InvoiceLive.Index do
  @moduledoc """
  The invoice list: everything synced up from the billing desks.

  Filters live in the query string, so a filtered view can be linked, bookmarked
  and reloaded. The rows are a LiveView stream and the view subscribes to
  `RealinvoiceCloud.Billing`, so an invoice created through
  `Billing.create_invoice/1` is prepended live — that is the path ingest will
  take, and it works today even though nothing calls it in production yet.
  """
  use RealinvoiceCloudWeb, :live_view

  alias RealinvoiceCloud.Billing

  @filter_keys ~w(from to node q)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Billing.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Invoices")
     |> assign(:nodes, Billing.list_store_nodes())
     |> stream_configure(:invoices, dom_id: &"invoice-#{&1.id}")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = Map.take(params, @filter_keys)
    invoices = Billing.list_invoices(filters)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:filtered?, filters != %{} and Enum.any?(filters, fn {_k, v} -> v != "" end))
     |> assign(:count, length(invoices))
     |> assign(:total, sum_grand_total(invoices))
     |> stream(:invoices, invoices, reset: true)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    filters =
      params
      |> Map.take(@filter_keys)
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/invoices?#{filters}", replace: true)}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/invoices")}
  end

  @impl true
  def handle_info({:invoice_created, invoice}, socket) do
    # Only surface it if it belongs in the view the user is actually looking at,
    # otherwise a filtered list would start showing rows that contradict its
    # own filters.
    if Billing.matches_filters?(invoice, socket.assigns.filters) do
      {:noreply,
       socket
       |> stream_insert(:invoices, invoice, at: 0)
       |> assign(:count, socket.assigns.count + 1)
       |> assign(:total, Decimal.add(socket.assigns.total, invoice.grand_total))
       |> assign(:nodes, Billing.list_store_nodes())}
    else
      {:noreply, socket}
    end
  end

  defp sum_grand_total(invoices) do
    Enum.reduce(invoices, Decimal.new("0.00"), &Decimal.add(&2, &1.grand_total))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active={:invoices}
      title="Invoices"
      subtitle="Everything your billing desks have sent up"
    >
      <div class="space-y-6">
        <.filter_bar filters={@filters} nodes={@nodes} filtered?={@filtered?} />

        <div class="flex items-baseline justify-between gap-4 text-sm">
          <p class="text-muted-foreground">
            {@count} {if @count == 1, do: "invoice", else: "invoices"}
          </p>
          <p class="text-muted-foreground">
            Total <span class="font-medium text-foreground">{money(@total)}</span>
          </p>
        </div>

        <div class="overflow-x-auto">
          <.table>
            <.table_header>
              <.table_row>
                <.table_head>Invoice No</.table_head>
                <.table_head>Date</.table_head>
                <.table_head>Customer</.table_head>
                <.table_head>Node</.table_head>
                <.table_head>Payment</.table_head>
                <.table_head class="text-right">Grand Total</.table_head>
              </.table_row>
            </.table_header>
            <.table_body phx-update="stream" id="invoices">
              <.table_row
                :for={{dom_id, invoice} <- @streams.invoices}
                id={dom_id}
                class="cursor-pointer"
                phx-click={JS.navigate(~p"/invoices/#{invoice}")}
              >
                <.table_cell class="font-medium">
                  <.link navigate={~p"/invoices/#{invoice}"} class="hover:underline">
                    {invoice.invoice_no}
                  </.link>
                </.table_cell>
                <.table_cell class="whitespace-nowrap">{date(invoice.date)}</.table_cell>
                <.table_cell>
                  <span :if={invoice.customer}>{invoice.customer.name}</span>
                  <span :if={is_nil(invoice.customer)} class="text-muted-foreground">
                    Counter sale
                  </span>
                </.table_cell>
                <.table_cell>
                  <.badge variant="secondary">{invoice.store_node_id}</.badge>
                </.table_cell>
                <.table_cell>{invoice.payment_type}</.table_cell>
                <.table_cell class="text-right font-medium whitespace-nowrap">
                  {money(invoice.grand_total)}
                </.table_cell>
              </.table_row>
            </.table_body>
          </.table>
        </div>

        <.empty_state
          :if={@count == 0}
          icon="hero-document-text"
          title={if @filtered?, do: "No matching invoices", else: "No invoices yet"}
          message={
            if @filtered?,
              do: "No invoice matches these filters.",
              else: "Invoices will appear here once your billing desks start syncing."
          }
        />
      </div>
    </Layouts.app>
    """
  end

  attr :filters, :map, required: true
  attr :nodes, :list, required: true
  attr :filtered?, :boolean, required: true

  defp filter_bar(assigns) do
    ~H"""
    <form
      id="invoice-filters"
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
          placeholder="Invoice number or customer"
          phx-debounce="300"
        />
      </div>

      <div class="space-y-1.5">
        <.label for="filter-from">From</.label>
        <.input id="filter-from" type="date" name="from" value={@filters["from"]} />
      </div>

      <div class="space-y-1.5">
        <.label for="filter-to">To</.label>
        <.input id="filter-to" type="date" name="to" value={@filters["to"]} />
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
    """
  end
end
