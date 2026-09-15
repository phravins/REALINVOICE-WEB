defmodule RealinvoiceCloudWeb.LoginRateLimitTest do
  @moduledoc """
  The limit as a person meets it: through POST /users/log-in and the login
  screen they land back on.
  """
  use RealinvoiceCloudWeb.ConnCase, async: true

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import RealinvoiceCloud.AccountsFixtures

  alias RealinvoiceCloud.Accounts.FailedLoginAttempt
  alias RealinvoiceCloud.Accounts.LoginThrottle
  alias RealinvoiceCloud.Repo

  setup do
    user = staff_user_fixture(%{email: "staff@example.com"})
    %{user: user, password: valid_user_password()}
  end

  defp sign_in(conn, email, password, ip \\ {203, 0, 113, 10}) do
    %{conn | remote_ip: ip}
    |> post(~p"/users/log-in", %{"user" => %{"email" => email, "password" => password}})
  end

  defp fail_n(conn, email, n, ip \\ {203, 0, 113, 10}) do
    for _ <- 1..n, do: sign_in(conn, email, "wrong-password", ip)
    :ok
  end

  # The wording the controller sets when a limit refuses the attempt.
  defp blocked_flash(conn), do: Phoenix.Flash.get(conn.assigns.flash, :too_many_attempts)

  describe "five failures then the right password" do
    test "the sixth attempt is refused even though the password is correct", %{
      conn: conn,
      password: password
    } do
      fail_n(conn, "staff@example.com", 5)

      conn = sign_in(conn, "staff@example.com", password)

      assert redirected_to(conn) == ~p"/users/log-in"
      # Not signed in, despite the password being right.
      refute get_session(conn, :user_token)
      assert blocked_flash(conn) =~ "Too many failed sign-in attempts"
    end

    test "four failures then the right password still signs in", %{
      conn: conn,
      password: password
    } do
      fail_n(conn, "staff@example.com", 4)

      conn = sign_in(conn, "staff@example.com", password)

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token)
    end

    test "signing in clears the failures, so the count starts again", %{
      conn: conn,
      password: password
    } do
      fail_n(conn, "staff@example.com", 4)
      assert LoginThrottle.failure_count(:email, "staff@example.com") == 4

      sign_in(conn, "staff@example.com", password)

      assert LoginThrottle.failure_count(:email, "staff@example.com") == 0
    end

    test "the block says nothing about whether the account exists", %{conn: conn} do
      fail_n(conn, "staff@example.com", 5)
      fail_n(conn, "ghost@example.com", 5, {198, 51, 100, 40})

      real = sign_in(conn, "staff@example.com", "whatever")
      ghost = sign_in(conn, "ghost@example.com", "whatever", {198, 51, 100, 40})

      assert blocked_flash(real) == blocked_flash(ghost)
    end
  end

  describe "the scope of a block" do
    test "another account from the same address still signs in", %{conn: conn} do
      other = staff_user_fixture(%{email: "owner@example.com"})
      fail_n(conn, "staff@example.com", 5)

      conn = sign_in(conn, other.email, valid_user_password())

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token)
    end

    test "the blocked account is still blocked from a different address", %{
      conn: conn,
      password: password
    } do
      fail_n(conn, "staff@example.com", 5)

      conn = sign_in(conn, "staff@example.com", password, {198, 51, 100, 77})

      refute get_session(conn, :user_token)
      assert blocked_flash(conn)
    end
  end

  describe "the window expiring" do
    test "the account signs in again once the failures age out", %{
      conn: conn,
      password: password
    } do
      fail_n(conn, "staff@example.com", 5)
      assert sign_in(conn, "staff@example.com", password) |> get_session(:user_token) == nil

      Repo.update_all(FailedLoginAttempt,
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -16 * 60, :second)]
      )

      conn = sign_in(conn, "staff@example.com", password)

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token)
    end
  end

  describe "the per-IP limit" do
    test "one source guessing across many accounts is stopped", %{conn: conn} do
      ip = {198, 51, 100, 9}
      for n <- 1..20, do: sign_in(conn, "victim#{n}@example.com", "wrong", ip)

      # A real account with the right password, from that address.
      conn = sign_in(conn, "staff@example.com", valid_user_password(), ip)

      refute get_session(conn, :user_token)
      assert blocked_flash(conn)
    end

    test "the same account from an untainted address is unaffected", %{
      conn: conn,
      password: password
    } do
      for n <- 1..20, do: sign_in(conn, "victim#{n}@example.com", "wrong", {198, 51, 100, 9})

      conn = sign_in(conn, "staff@example.com", password, {203, 0, 113, 200})

      assert get_session(conn, :user_token)
    end
  end

  describe "what the login screen shows" do
    test "a blocked attempt explains itself, instead of the usual wrong-password error", %{
      conn: conn,
      password: password
    } do
      fail_n(conn, "staff@example.com", 5)
      conn = sign_in(conn, "staff@example.com", password)

      {:ok, _lv, html} = conn |> recycle() |> get(~p"/users/log-in") |> live()

      assert html =~ "Too many attempts"
      assert html =~ "Too many failed sign-in attempts"
      refute html =~ "Invalid email or password"
    end

    test "an ordinary wrong password still shows the ordinary error", %{conn: conn} do
      conn = sign_in(conn, "staff@example.com", "wrong-password")

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      refute blocked_flash(conn)
    end
  end

  describe "logging" do
    test "warns when an account crosses the limit" do
      conn = build_conn()

      log =
        capture_log(fn ->
          fail_n(conn, "staff@example.com", 5)
        end)

      assert log =~ "[login-throttle]"
      assert log =~ "staff@example.com"
      assert log =~ "is now blocked"
    end

    test "warns each time a blocked account is tried again — the attack signal" do
      conn = build_conn()
      fail_n(conn, "staff@example.com", 5)

      log =
        capture_log(fn ->
          sign_in(conn, "staff@example.com", valid_user_password())
        end)

      assert log =~ "[login-throttle] refused a sign-in"
      assert log =~ "blocked by email"
    end

    test "warns when a source crosses the IP limit" do
      conn = build_conn()

      log =
        capture_log(fn ->
          for n <- 1..20, do: sign_in(conn, "victim#{n}@example.com", "wrong", {198, 51, 100, 9})
        end)

      assert log =~ "[login-throttle] ip 198.51.100.9"
      assert log =~ "is now blocked"
    end
  end

  describe "what is not rate limited" do
    test "a magic-link sign-in still works for a password-blocked account", %{
      conn: conn,
      user: user
    } do
      fail_n(conn, "staff@example.com", 5)

      # The recovery path proves control of the mailbox, so a password guesser
      # gains nothing from it — and blocking it would lock out the very person
      # trying to recover.
      {encoded_token, _hashed} = generate_user_magic_link_token(user)
      conn = post(conn, ~p"/users/log-in", %{"user" => %{"token" => encoded_token}})

      assert get_session(conn, :user_token)
    end
  end
end
