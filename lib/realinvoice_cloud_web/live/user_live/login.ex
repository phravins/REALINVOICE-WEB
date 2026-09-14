defmodule RealinvoiceCloudWeb.UserLive.Login do
  @moduledoc """
  Staff login.

  Password is the primary path — accounts are provisioned by an operator with a
  password already set (see `priv/repo/seeds.exs`), so there is no sign-up link
  here. The emailed login link doubles as the password-reset route: it signs you
  in, and you set a new password from Settings.
  """
  use RealinvoiceCloudWeb, :live_view

  alias RealinvoiceCloud.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <div class="mb-8">
        <h1 class="text-xl font-semibold tracking-tight">
          {if @current_scope, do: "Confirm it's you", else: "Sign in"}
        </h1>
        <p class="mt-1.5 text-sm text-muted-foreground">
          <%= if @current_scope do %>
            Re-enter your password to continue with sensitive changes to your account.
          <% else %>
            Back-office access for RealInvoice staff.
          <% end %>
        </p>
      </div>

      <div
        :if={@too_many_attempts}
        id="too-many-attempts"
        role="alert"
        class="mb-6 rounded-md border border-destructive/40 bg-destructive/5 px-4 py-3"
      >
        <p class="flex items-center gap-1.5 text-sm font-medium text-destructive">
          <span class="hero-exclamation-triangle-mini size-4 bg-destructive" /> Too many attempts
        </p>
        <p class="mt-1 text-sm text-muted-foreground">{@too_many_attempts}</p>
      </div>

      <.form
        :let={f}
        for={@form}
        id="login_form_password"
        action={~p"/users/log-in"}
        phx-submit="submit_password"
        phx-trigger-action={@trigger_submit}
        class="space-y-5"
      >
        <.form_item>
          <.form_label field={f[:email]}>Email</.form_label>
          <.form_control>
            <.input
              readonly={!!@current_scope}
              field={f[:email]}
              type="email"
              autocomplete="username"
              spellcheck="false"
              placeholder="you@company.com"
              required
              phx-mounted={JS.focus()}
            />
          </.form_control>
          <.form_message field={f[:email]} />
        </.form_item>

        <.form_item>
          <.form_label field={@form[:password]}>Password</.form_label>
          <.form_control>
            <.input
              field={@form[:password]}
              type="password"
              autocomplete="current-password"
              spellcheck="false"
              required
            />
          </.form_control>
          <.form_message field={@form[:password]} />
        </.form_item>

        <div class="space-y-2 pt-1">
          <.button
            class="w-full"
            name={@form[:remember_me].name}
            value="true"
            phx-disable-with="Signing in…"
          >
            Sign in and stay signed in
          </.button>
          <.button variant="ghost" class="w-full" phx-disable-with="Signing in…">
            Sign in just this once
          </.button>
        </div>
      </.form>

      <.separator class="my-8" />

      <div class="space-y-3">
        <p class="text-sm text-muted-foreground">
          Forgotten your password? Have a one-time sign-in link emailed to you, then set a
          new one from Settings.
        </p>

        <.form
          :let={f}
          for={@form}
          id="login_form_magic"
          action={~p"/users/log-in"}
          phx-submit="submit_magic"
          class="flex flex-col gap-2 sm:flex-row"
        >
          <.input
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            autocomplete="username"
            spellcheck="false"
            placeholder="you@company.com"
            class="sm:flex-1"
            required
          />
          <.button variant="outline" phx-disable-with="Sending…">Email me a link</.button>
        </.form>

        <p :if={local_mail_adapter?()} class="text-xs text-muted-foreground">
          Development mail adapter in use — sent mail shows up at <.link
            href="/dev/mailbox"
            class="underline underline-offset-2"
          >/dev/mailbox</.link>.
        </p>
      </div>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok,
     socket
     |> assign(form: form, trigger_submit: false, page_title: "Sign in")
     # Set by UserSessionController when a limit refused the attempt. Shown
     # inline rather than as a passing toast: it explains why a correct
     # password is being turned away, which the generic error would not.
     |> assign(:too_many_attempts, Phoenix.Flash.get(socket.assigns.flash, :too_many_attempts))}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )
    end

    info =
      "If your email is in our system, you will receive instructions for logging in shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  defp local_mail_adapter? do
    Application.get_env(:realinvoice_cloud, RealinvoiceCloud.Mailer)[:adapter] ==
      Swoosh.Adapters.Local
  end
end
