defmodule RealinvoiceCloudWeb.SectionLive do
  @moduledoc """
  Placeholder pages for the sections that are not built yet.

  Invoices, Customers, Items and Nodes all render the same "coming soon" block.
  They exist now so the shell's navigation is complete and every sidebar entry
  goes somewhere real; each one gets its own LiveView when it grows content.
  """
  use RealinvoiceCloudWeb, :live_view

  @sections %{
    invoices: %{
      title: "Invoices",
      subtitle: "Invoices synced up from your billing desks",
      icon: "hero-document-text",
      detail:
        "Every invoice closed on a billing desk will land here, searchable by customer, date and desk."
    },
    customers: %{
      title: "Customers",
      subtitle: "The customer book, merged across desks",
      icon: "hero-users",
      detail:
        "Customer records from each desk will be reconciled here into a single book for the whole business."
    },
    items: %{
      title: "Items",
      subtitle: "Your product and service catalogue",
      icon: "hero-cube",
      detail:
        "The catalogue each desk bills against will be listed here, with the prices and tax rates in use."
    },
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
