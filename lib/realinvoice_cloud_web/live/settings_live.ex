defmodule RealinvoiceCloudWeb.SettingsLive do
  @moduledoc """
  Back-office settings.

  Only the Account section exists at this stage: who is signed in, what role
  they hold, and where to go to change their email or password.
  """
  use RealinvoiceCloudWeb, :live_view

  alias RealinvoiceCloud.Nodes

  @impl true
  def mount(_params, _session, socket) do
    nodes = Nodes.list_nodes()

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:node_count, length(nodes))
     |> assign(:active_node_count, Enum.count(nodes, &(&1.status == "active")))
     |> assign(:owner?, socket.assigns.current_scope.user.role == "owner")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active={:settings}
      title="Settings"
      subtitle="This back-office account and how it is configured"
    >
      <div class="max-w-2xl space-y-12">
        <section>
          <.section_heading
            title="Account"
            description="The staff account you are signed in with. Back-office accounts are separate from the cashier logins on each billing desk."
          />

          <.detail_list>
            <:row label="Email">{@current_scope.user.email}</:row>
            <:row label="Role">
              <span class="capitalize">{@current_scope.user.role}</span>
              <span class="ml-2 text-muted-foreground">
                {role_description(@current_scope.user.role)}
              </span>
            </:row>
            <:row label="Confirmed">{format_date(@current_scope.user.confirmed_at)}</:row>
            <:row label="Account created">{format_date(@current_scope.user.inserted_at)}</:row>
          </.detail_list>

          <div class="mt-5 flex flex-wrap gap-2">
            <.link navigate={~p"/users/settings"}>
              <.button variant="outline" size="sm">Change email or password</.button>
            </.link>
            <.link href={~p"/users/log-out"} method="delete">
              <.button variant="ghost" size="sm">Log out</.button>
            </.link>
          </div>
        </section>

        <section>
          <.section_heading
            title="Nodes"
            description="The billing desks allowed to sync into this account, and the tokens they use."
          />

          <.detail_list>
            <:row label="Registered desks">
              {@node_count} {if @node_count == 1, do: "desk", else: "desks"}
            </:row>
            <:row label="Able to sync">
              {@active_node_count} active
            </:row>
          </.detail_list>

          <div class="mt-5">
            <.link :if={@owner?} navigate={~p"/nodes"}>
              <.button variant="outline" size="sm">Manage nodes</.button>
            </.link>
            <p :if={!@owner?} class="text-sm text-muted-foreground">
              Only an owner can register or revoke a billing desk.
            </p>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp role_description("owner"), do: "— full access to this account"
  defp role_description(_), do: "— back-office staff"

  defp format_date(nil), do: "—"

  defp format_date(%DateTime{} = at) do
    Calendar.strftime(at, "%d %b %Y, %H:%M UTC")
  end
end
