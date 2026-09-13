defmodule RealinvoiceCloudWeb.SectionLive do
  @moduledoc """
  Placeholder page for a section that is not built yet.

  Only Nodes is left: desk enrolment and sync status cannot be built until the
  ingest API exists and desks actually register. Invoices, Customers and Items
  have grown into their own LiveViews.
  """
  use RealinvoiceCloudWeb, :live_view

  @sections %{
    nodes: %{
      title: "Nodes",
      subtitle: "The billing desks reporting into this account",
      icon: "hero-server-stack",
      detail:
        "Each desk running the desktop app will register here, showing when it last synced and what it sent."
    }
  }

  @impl true
  def mount(_params, _session, socket) do
    section = Map.fetch!(@sections, socket.assigns.live_action)

    {:ok,
     socket
     |> assign(:section, section)
     |> assign(:page_title, section.title)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active={@live_action}
      title={@section.title}
      subtitle={@section.subtitle}
    >
      <.empty_state
        icon={@section.icon}
        title="Coming soon"
        message={"#{@section.title} arrives once the desktop app starts syncing."}
      >
        {@section.detail}
      </.empty_state>
    </Layouts.app>
    """
  end
end
