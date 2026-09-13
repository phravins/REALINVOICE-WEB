defmodule RealinvoiceCloudWeb.SettingsLive do
  @moduledoc """
  Back-office settings.

  Only the Account section exists at this stage: who is signed in, what role
  they hold, and where to go to change their email or password.
  """
  use RealinvoiceCloudWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Settings")}
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
            title="Sync"
            description="How billing desks connect to this account."
          />

          <p class="text-sm leading-relaxed text-muted-foreground">
            Nothing to configure yet. Desk enrolment and sync credentials arrive with the
            ingest API, once the desktop app has a sync worker to talk to it.
          </p>
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
