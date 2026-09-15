defmodule RealinvoiceCloudWeb.UserSessionController do
  use RealinvoiceCloudWeb, :controller

  alias RealinvoiceCloud.Accounts
  alias RealinvoiceCloud.Accounts.LoginThrottle
  alias RealinvoiceCloudWeb.UserAuth

  require Logger

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, "User confirmed successfully.")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  # magic link login
  defp create(conn, %{"user" => %{"token" => token} = user_params}, info) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      _ ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # email + password login
  defp create(conn, %{"user" => user_params}, info) do
    %{"email" => email, "password" => password} = user_params
    ip = peer_address(conn)

    # Checked before the password, not after: a correct password offered while
    # blocked has to be refused too, or the limit protects nothing.
    case LoginThrottle.check(email, ip) do
      {:blocked, block} ->
        Logger.warning(
          "[login-throttle] refused a sign-in for #{String.slice(email, 0, 160)} from #{ip} " <>
            "(blocked by #{block.scope}, #{block.failures} failures, " <>
            "#{block.retry_after_seconds}s remaining)"
        )

        conn
        |> put_flash(:too_many_attempts, LoginThrottle.blocked_message(block))
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: ~p"/users/log-in")

      :ok ->
        if user = Accounts.get_user_by_email_and_password(email, password) do
          LoginThrottle.clear_failures(email)

          conn
          |> put_flash(:info, info)
          |> UserAuth.log_in_user(user, user_params)
        else
          LoginThrottle.record_failure(email, ip)

          # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
          conn
          |> put_flash(:error, "Invalid email or password")
          |> put_flash(:email, String.slice(email, 0, 160))
          |> redirect(to: ~p"/users/log-in")
        end
    end
  end

  # The peer address as Plug reports it. Behind a proxy this needs RemoteIp
  # configured with trusted ranges — see LoginThrottle's docs on why
  # x-forwarded-for is not read here.
  defp peer_address(conn) do
    case conn.remote_ip do
      nil -> "unknown"
      ip -> ip |> :inet.ntoa() |> to_string()
    end
  end

  def update_password(conn, %{"user" => user_params} = params) do
    user = conn.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)
    {:ok, {_user, expired_tokens}} = Accounts.update_user_password(user, user_params)

    # disconnect all existing LiveViews with old sessions
    UserAuth.disconnect_sessions(expired_tokens)

    conn
    |> put_session(:user_return_to, ~p"/users/settings")
    |> create(params, "Password updated successfully!")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
