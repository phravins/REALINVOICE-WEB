defmodule RealinvoiceCloudWeb.DashboardLive do
  @moduledoc """
  The back office landing page: today's trading across every billing desk.

  The figures come straight from the invoices the desks have sent up. Until the
  ingest API exists that means the sample data in `priv/repo/seeds.exs`, so an
  empty database still falls back to the "nothing has synced yet" state.
  """
  use RealinvoiceCloudWeb, :live_view

  alias RealinvoiceCloud.Billing

  @impl true
  def mount(_params, _session, socket) do
    # New invoices change every number on this page, so recompute on broadcast.
    if connected?(socket), do: Billing.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> load_metrics()}
  end

  @impl true
  def handle_info({:invoice_created, _invoice}, socket) do
    {:noreply, load_metrics(socket)}
  end

  defp load_metrics(socket) do
    metrics = Billing.dashboard_metrics()

    socket
    |> assign(:metrics, metrics)
    |> assign(:any_invoices?, Billing.any_invoices?())
    |> assign(:busiest, busiest_node(metrics.by_node))
  end

  defp busiest_node([]), do: nil

  defp busiest_node(by_node) do
    Enum.max_by(by_node, & &1.revenue, Decimal)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active={:dashboard}
      title="Dashboard"
      subtitle={"Trading as of #{date(@metrics.date)}"}
    >
      <div :if={@any_invoices?} class="space-y-10">
        <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <.stat_card
            label="Revenue today"
            value={money(@metrics.today.revenue)}
            hint={"across #{@metrics.today.count} #{pluralise(@metrics.today.count, "invoice")}"}
          />
          <.stat_card
            label="Invoices today"
            value={to_string(@metrics.today.count)}
            hint={"from #{length(@metrics.by_node)} #{pluralise(length(@metrics.by_node), "desk")}"}
          />
          <.stat_card
            label="Revenue this month"
            value={money(@metrics.month.revenue)}
            hint={"across #{@metrics.month.count} #{pluralise(@metrics.month.count, "invoice")}"}
          />
          <.stat_card
            label="Busiest desk today"
            value={(@busiest && @busiest.node) || "—"}
            hint={(@busiest && money(@busiest.revenue)) || "no sales yet today"}
          />
        </div>

        <section>
          <.section_heading
            title="Revenue by node, today"
            description="Which billing desk took the money."
          />

          <div :if={@metrics.by_node != []} class="space-y-3">
            <div :for={row <- @metrics.by_node} class="space-y-1.5">
              <div class="flex items-baseline justify-between gap-4 text-sm">
                <span class="font-medium">{row.node}</span>
                <span class="text-muted-foreground">
                  {money(row.revenue)}
                  <span class="ml-2">
                    {row.count} {pluralise(row.count, "invoice")}
                  </span>
                </span>
              </div>
              <div class="h-2 w-full overflow-hidden rounded-full bg-muted">
                <div
                  class="h-full rounded-full bg-primary"
                  style={"width: #{share_of_total(row.revenue, @metrics.today.revenue)}%"}
                />
              </div>
            </div>
          </div>

          <p :if={@metrics.by_node == []} class="text-sm text-muted-foreground">
            No desk has billed anything today. The most recent invoice is dated {date(
              @metrics.last_invoice_at
            )}.
          </p>
        </section>

        <section>
          <.section_heading title="Shortcuts" />
          <div class="flex flex-wrap gap-2">
            <.link navigate={
              ~p"/invoices?#{[from: Date.to_iso8601(@metrics.date), to: Date.to_iso8601(@metrics.date)]}"
            }>
              <.button variant="outline" size="sm">Today's invoices</.button>
            </.link>
            <.link navigate={~p"/invoices"}>
              <.button variant="outline" size="sm">All invoices</.button>
            </.link>
            <.link navigate={~p"/customers"}>
              <.button variant="outline" size="sm">Customers</.button>
            </.link>
          </div>
        </section>
      </div>

      <.empty_state
        :if={!@any_invoices?}
        icon="hero-chart-bar-square"
        title="No data yet"
        message="This will populate once your billing desks start syncing."
      >
        Each desk pushes its invoices, customers and items up as it closes them.
        Until the first desk is connected there is nothing to show here.
      </.empty_state>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :hint, :string, default: nil

  defp stat_card(assigns) do
    ~H"""
    <.card class="shadow-none">
      <.card_content class="p-5">
        <p class="text-xs font-medium uppercase tracking-wide text-muted-foreground">{@label}</p>
        <p class="mt-2 text-2xl font-semibold tabular-nums">{@value}</p>
        <p :if={@hint} class="mt-1 text-xs text-muted-foreground">{@hint}</p>
      </.card_content>
    </.card>
    """
  end

  defp pluralise(1, word), do: word
  defp pluralise(_count, word), do: word <> "s"

  # Bar width as a percentage of the day's takings. Guards against a zero total,
  # which would otherwise be a division by zero on a day with no sales.
  defp share_of_total(_revenue, total) when total in [nil, 0], do: 0

  defp share_of_total(revenue, %Decimal{} = total) do
    if Decimal.eq?(total, 0) do
      0
    else
      revenue
      |> Decimal.div(total)
      |> Decimal.mult(100)
      |> Decimal.round(1)
      |> Decimal.to_string(:normal)
    end
  end

  defp share_of_total(_revenue, _total), do: 0
end
