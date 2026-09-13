defmodule RealinvoiceCloudWeb.UserLive.Settings do
  @moduledoc """
  Sign-in details for the current account: email address and password.

  Guarded by sudo mode, so reaching it re-prompts for the password if the
  session is older than a few minutes.
  """
  use RealinvoiceCloudWeb, :live_view

  on_mount {RealinvoiceCloudWeb.UserAuth, :require_sudo_mode}

  alias RealinvoiceCloud.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active={:settings}
      title="Email & password"
      subtitle="Change the sign-in details for this back-office account"
    >
      <div class="max-w-2xl space-y-12">
        <section>
          <.section_heading
            title="Email address"
            description="Changing this sends a confirmation link to the new address. The change only takes effect once that link is opened."
          />

          <.form
            for={@email_form}
            id="email_form"
            phx-submit="update_email"
            phx-change="validate_email"
            class="space-y-5"
          >
            <.form_item>
              <.form_label field={@email_form[:email]}>Email</.form_label>
              <.form_control>
                <.input
                  field={@email_form[:email]}
                  type="email"
                  autocomplete="username"
                  spellcheck="false"
                  required
                />
              </.form_control>
              <.form_message field={@email_form[:email]} />
            </.form_item>

            <.button phx-disable-with="Changing…">Change email</.button>
          </.form>
        </section>

        <section>
          <.section_heading
            title="Password"
            description="Set a new password for signing in."
          />

          <.form
            for={@password_form}
            id="password_form"
            action={~p"/users/update-password"}
            method="post"
            phx-change="validate_password"
            phx-submit="update_password"
            phx-trigger-action={@trigger_submit}
            class="space-y-5"
          >
            <input
              name={@password_form[:email].name}
              type="hidden"
              id="hidden_user_email"
              spellcheck="false"
              value={@current_email}
            />

            <.form_item>
              <.form_label field={@password_form[:password]}>New password</.form_label>
              <.form_control>
                <.input
                  field={@password_form[:password]}
                  type="password"
                  autocomplete="new-password"
                  spellcheck="false"
                  required
                />
              </.form_control>
              <.form_message field={@password_form[:password]} />
            </.form_item>

            <.form_item>
              <.form_label field={@password_form[:password_confirmation]}>
                Confirm new password
              </.form_label>
              <.form_control>
                <.input
                  field={@password_form[:password_confirmation]}
                  type="password"
                  autocomplete="new-password"
                  spellcheck="false"
                />
              </.form_control>
              <.form_message field={@password_form[:password_confirmation]} />
            </.form_item>

            <.button phx-disable-with="Saving…">Save password</.button>
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)

    {:ok, assign(socket, :page_title, "Email & password")}
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        info = "A link to confirm your email change has been sent to the new address."
        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end
end
