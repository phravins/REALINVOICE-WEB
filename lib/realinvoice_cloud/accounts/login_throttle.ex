defmodule RealinvoiceCloud.Accounts.LoginThrottle do
  @moduledoc """
  Limits how often a password login may be attempted and fail.

  Two independent limits, both over the same sliding window:

    * **per email** — 5 failures blocks that account. This is the one that
      stops someone working through a password list against a known address.
    * **per IP** — 20 failures blocks the source. Without it, the per-email
      limit is trivially sidestepped by spraying one password across many
      addresses from the same machine.

  Either limit alone refuses the attempt. Both are configurable:

      config :realinvoice_cloud, RealinvoiceCloud.Accounts.LoginThrottle,
        max_failures_per_email: 5,
        max_failures_per_ip: 20,
        window_minutes: 15,
        retention_hours: 24

  ## Why a table and not an in-memory rate limiter

  A counter in ETS is faster, but it is also per-node and it is empty again
  after every restart — a deploy, or a crash, hands an attacker a fresh five
  attempts. Rows in Postgres survive both, count correctly if this app is ever
  run on more than one node, and leave a record an admin can query when the
  logs suggest something is going on. At the volume of a back-office login
  screen the cost of two indexed counts is irrelevant.

  ## The window is sliding

  A block is not a fixed penalty period: an attempt is blocked while there are
  at least `max_failures` failures in the last `window_minutes`. It lifts as
  those failures age out, so `retry_after/1` reports when the oldest failure
  still holding the block expires — not a flat 15 minutes from the last try.

  ## On the IP

  `ip` is the peer address Plug reports. Behind a load balancer or CDN that is
  the proxy's address, and every request appears to come from one place, which
  would make the per-IP limit fire for everyone at once. A deployment behind a
  proxy needs `RemoteIp` (or equivalent) configured with its **trusted** proxy
  ranges. `x-forwarded-for` must never be read without that: it is caller-
  supplied, so trusting it blindly would let an attacker defeat the per-IP
  limit by putting a new address in a header.
  """

  import Ecto.Query, warn: false

  alias RealinvoiceCloud.Accounts.FailedLoginAttempt
  alias RealinvoiceCloud.Repo

  require Logger

  @defaults [
    max_failures_per_email: 5,
    max_failures_per_ip: 20,
    window_minutes: 15,
    retention_hours: 24
  ]

  @doc """
  Whether this attempt may proceed.

  Returns `:ok`, or `{:blocked, info}` where `info` carries `:scope`
  (`:email` or `:ip`) and `:retry_after_seconds`.

  Call this **before** checking the password: a correct password offered while
  blocked must still be refused, or the limit protects nothing.
  """
  def check(email, ip) do
    email = normalise_email(email)
    ip = to_string(ip)

    with :ok <- check_scope(:email, email, config(:max_failures_per_email)),
         :ok <- check_scope(:ip, ip, config(:max_failures_per_ip)) do
      :ok
    end
  end

  defp check_scope(scope, value, max_failures) do
    timestamps = failures_in_window(scope, value)

    if length(timestamps) >= max_failures do
      {:blocked,
       %{
         scope: scope,
         failures: length(timestamps),
         retry_after_seconds: retry_after_seconds(timestamps, max_failures)
       }}
    else
      :ok
    end
  end

  @doc """
  Records one failed attempt, and warns in the log if it crosses a limit.
  """
  def record_failure(email, ip) do
    email = normalise_email(email)
    ip = to_string(ip)

    Repo.insert!(%FailedLoginAttempt{
      email: email,
      ip: ip,
      inserted_at: DateTime.utc_now()
    })

    warn_if_limit_reached(:email, email, ip, config(:max_failures_per_email))
    warn_if_limit_reached(:ip, ip, ip, config(:max_failures_per_ip))

    prune()
    :ok
  end

  @doc """
  Forgets an email's failures after it signs in successfully.

  Only the email's. Clearing the IP's would let anyone holding one valid
  account reset the per-IP limit between bursts of guessing.
  """
  def clear_failures(email) do
    email = normalise_email(email)

    {count, _} =
      Repo.delete_all(from a in FailedLoginAttempt, where: a.email == ^email)

    if count > 0 do
      Logger.info(
        "[login-throttle] cleared #{count} failed attempt(s) for #{email} after success"
      )
    end

    :ok
  end

  @doc """
  The message shown to someone who has been blocked.

  Deliberately the same wording whether the account exists or not, and whether
  the block is by email or by address — it is not a place to tell a caller
  anything about our records.
  """
  def blocked_message(%{retry_after_seconds: seconds}) do
    "Too many failed sign-in attempts. Try again in #{humanise(seconds)}."
  end

  @doc """
  How many failures are currently counted against an email, for tests and for
  anyone poking at this in a console.
  """
  def failure_count(:email, email), do: length(failures_in_window(:email, normalise_email(email)))
  def failure_count(:ip, ip), do: length(failures_in_window(:ip, to_string(ip)))

  ## Internals

  defp failures_in_window(scope, value) do
    since = DateTime.add(DateTime.utc_now(), -config(:window_minutes) * 60, :second)

    from(a in FailedLoginAttempt,
      where: a.inserted_at >= ^since,
      order_by: [asc: a.inserted_at],
      select: a.inserted_at
    )
    |> scope_where(scope, value)
    |> Repo.all()
  end

  defp scope_where(query, :email, email), do: where(query, [a], a.email == ^email)
  defp scope_where(query, :ip, ip), do: where(query, [a], a.ip == ^ip)

  # The block lifts once enough of the failures holding it have aged out —
  # which is when the oldest one that still counts leaves the window.
  defp retry_after_seconds(timestamps, max_failures) do
    releasing = Enum.at(timestamps, length(timestamps) - max_failures)
    expires_at = DateTime.add(releasing, config(:window_minutes) * 60, :second)

    expires_at
    |> DateTime.diff(DateTime.utc_now())
    |> max(1)
  end

  defp warn_if_limit_reached(scope, value, ip, max_failures) do
    count = length(failures_in_window(scope, value))

    cond do
      count == max_failures ->
        Logger.warning(
          "[login-throttle] #{scope} #{value} reached #{count} failed sign-in attempts " <>
            "in #{config(:window_minutes)}m and is now blocked (from #{ip})"
        )

      count > max_failures ->
        # Still trying while blocked is the interesting signal: a person who
        # forgot their password stops, a script does not.
        Logger.warning(
          "[login-throttle] #{scope} #{value} attempted again while blocked " <>
            "(#{count} failures in #{config(:window_minutes)}m, from #{ip})"
        )

      true ->
        :ok
    end
  end

  @doc """
  Deletes attempts older than the retention period.

  Retention is longer than the counting window on purpose: the extra history is
  no longer blocking anyone, but it is what makes a run of lockouts legible
  after the fact.
  """
  def prune do
    cutoff = DateTime.add(DateTime.utc_now(), -config(:retention_hours) * 3600, :second)
    {count, _} = Repo.delete_all(from a in FailedLoginAttempt, where: a.inserted_at < ^cutoff)
    count
  end

  defp normalise_email(nil), do: ""
  defp normalise_email(email), do: email |> to_string() |> String.trim() |> String.downcase()

  defp humanise(seconds) when seconds < 60, do: "a few seconds"
  defp humanise(seconds) when seconds < 120, do: "about a minute"
  defp humanise(seconds), do: "about #{div(seconds + 59, 60)} minutes"

  defp config(key) do
    :realinvoice_cloud
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, Keyword.fetch!(@defaults, key))
  end
end
