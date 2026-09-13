defmodule RealinvoiceCloudWeb.DashboardLive do
  @moduledoc """
  The back office landing page.

  Empty by design for now: nothing can populate it until the desktop app's sync
  worker exists and starts pushing invoices up.
  """
  use RealinvoiceCloudWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Dashboard")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active={:dashboard}
      title="Dashboard"
      subtitle="Everything your billing desks send up, in one place"
    >
      <.empty_state
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
end
