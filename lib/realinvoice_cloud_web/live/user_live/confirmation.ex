defmodule RealinvoiceCloudWeb.UserLive.Confirmation do
  @moduledoc """
  Lands a one-time sign-in link and turns it into a session.

  This is where the "email me a link" path from the login screen ends up, and
  where a newly provisioned account confirms itself.
  """
  use RealinvoiceCloudWeb, :live_view

  alias RealinvoiceCloud.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <div class="mb-8">
        <h1 class="text-xl font-semibold tracking-tight">
          {if @user.confirmed_at, do: "Welcome back", else: "Confirm your account"}
        </h1>
        <p class="mt-1.5 text-sm text-muted-foreground">{@user.email}</p>
      </div>

      <.form
        :if={!@user.confirmed_at}
        for={@form}
        id="confirmation_form"
        phx-mounted={JS.focus_first()}
        phx-submit="submit"
        action={~p"/users/log-in?_action=confirmed"}
        phx-trigger-action={@trigger_submit}
        class="space-y-2"
      >
        <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
        <.button
          name={@form[:remember_me].name}
          value="true"
          phx-disable-with="Confirming…"
          class="w-full"
        >
          Confirm and stay signed in
        </.button>
        <.button variant="ghost" phx-disable-with="Confirming…" class="w-full">
          Confirm and sign in just this once
        </.button>
      </.form>

      <.form
        :if={@user.confirmed_at}
        for={@form}
        id="login_form"
        phx-submit="submit"
        phx-mounted={JS.focus_first()}
        action={~p"/users/log-in"}
        phx-trigger-action={@trigger_submit}
        class="space-y-2"
      >
        <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
        <%= if @current_scope do %>
          <.button phx-disable-with="Signing in…" class="w-full">Sign in</.button>
        <% else %>
          <.button
            name={@form[:remember_me].name}
            value="true"
            phx-disable-with="Signing in…"
            class="w-full"
          >
            Keep me signed in on this device
          </.button>
          <.button variant="ghost" phx-disable-with="Signing in…" class="w-full">
            Sign me in just this once
          </.button>
        <% end %>
      </.form>

      <p :if={!@user.confirmed_at} class="mt-8 text-sm text-muted-foreground">
        You can set a password afterwards from Settings, and sign in with it next time.
      </p>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "user")

      {:ok,
       socket
       |> assign(user: user, form: form, trigger_submit: false, page_title: "Sign in"),
       temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, "Sign-in link is invalid or it has expired.")
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "user"), trigger_submit: true)}
  end
end
