defmodule RealinvoiceCloud.Accounts.LoginThrottleTest do
  use RealinvoiceCloud.DataCase, async: true

  alias RealinvoiceCloud.Accounts.FailedLoginAttempt
  alias RealinvoiceCloud.Accounts.LoginThrottle

  @ip "203.0.113.10"

  defp fail(email, ip, times \\ 1) do
    for _ <- 1..times, do: LoginThrottle.record_failure(email, ip)
    :ok
  end

  # Moves existing rows back in time, which is how these tests reach the far
  # side of a 15 minute window without waiting 15 minutes.
  defp age(minutes) do
    Repo.update_all(
      from(a in FailedLoginAttempt),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -minutes * 60, :second)]
    )
  end

  defp age_oldest(count, minutes) do
    ids =
      from(a in FailedLoginAttempt, order_by: [asc: a.inserted_at], limit: ^count, select: a.id)
      |> Repo.all()

    Repo.update_all(
      from(a in FailedLoginAttempt, where: a.id in ^ids),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -minutes * 60, :second)]
    )
  end

  describe "the per-email limit" do
    test "lets the first four failures through" do
      fail("staff@example.com", @ip, 4)

      assert LoginThrottle.check("staff@example.com", @ip) == :ok
    end

    test "blocks on the fifth" do
      fail("staff@example.com", @ip, 5)

      assert {:blocked, %{scope: :email}} = LoginThrottle.check("staff@example.com", @ip)
    end

    test "reports how long is left" do
      fail("staff@example.com", @ip, 5)

      {:blocked, block} = LoginThrottle.check("staff@example.com", @ip)

      assert block.failures == 5
      assert block.retry_after_seconds > 0
      assert block.retry_after_seconds <= 15 * 60
    end

    test "does not touch a different account" do
      fail("staff@example.com", @ip, 5)

      assert {:blocked, _} = LoginThrottle.check("staff@example.com", @ip)
      # A different email from a different address is unaffected.
      assert LoginThrottle.check("owner@example.com", "198.51.100.7") == :ok
    end

    test "treats the email case- and whitespace-insensitively" do
      fail("Staff@Example.com ", @ip, 5)

      assert {:blocked, _} = LoginThrottle.check("staff@example.com", @ip)
      assert {:blocked, _} = LoginThrottle.check("  STAFF@EXAMPLE.COM", @ip)
    end

    test "counts failures for an email with no account, so a block reveals nothing" do
      fail("nobody@example.com", @ip, 5)

      assert {:blocked, %{scope: :email}} = LoginThrottle.check("nobody@example.com", @ip)
    end
  end

  describe "the window expiring" do
    test "lets the account back in once the failures age out" do
      fail("staff@example.com", @ip, 5)
      assert {:blocked, _} = LoginThrottle.check("staff@example.com", @ip)

      age(16)

      assert LoginThrottle.check("staff@example.com", @ip) == :ok
    end

    test "stays blocked while the failures are still inside the window" do
      fail("staff@example.com", @ip, 5)

      age(14)

      assert {:blocked, _} = LoginThrottle.check("staff@example.com", @ip)
    end

    test "slides: ageing out one of five is enough to let an attempt through" do
      fail("staff@example.com", @ip, 5)
      assert {:blocked, _} = LoginThrottle.check("staff@example.com", @ip)

      age_oldest(1, 16)

      assert LoginThrottle.check("staff@example.com", @ip) == :ok
      assert LoginThrottle.failure_count(:email, "staff@example.com") == 4
    end

    test "counts the release from the failure that is still holding the block" do
      fail("staff@example.com", @ip, 5)
      # The oldest four are nearly out of the window; the fifth is fresh.
      age_oldest(4, 14)

      {:blocked, block} = LoginThrottle.check("staff@example.com", @ip)

      # Only one failure has to age out, and that one has a minute left.
      assert block.retry_after_seconds <= 60
    end
  end

  describe "the per-IP limit" do
    test "blocks a source spraying many different accounts" do
      for n <- 1..20, do: fail("victim#{n}@example.com", "198.51.100.9")

      # No single account is near its own limit …
      assert LoginThrottle.failure_count(:email, "victim1@example.com") == 1
      # … but the source is.
      assert {:blocked, %{scope: :ip}} =
               LoginThrottle.check("someone@example.com", "198.51.100.9")
    end

    test "leaves a different source alone" do
      for n <- 1..20, do: fail("victim#{n}@example.com", "198.51.100.9")

      assert LoginThrottle.check("someone@example.com", "203.0.113.55") == :ok
    end

    test "lets fewer than the limit through" do
      for n <- 1..19, do: fail("victim#{n}@example.com", "198.51.100.9")

      assert LoginThrottle.check("someone@example.com", "198.51.100.9") == :ok
    end

    test "applies independently of the email limit" do
      # Five failures for one email from one address trips the email limit
      # first, but a sixth email from that address is still fine.
      fail("staff@example.com", "198.51.100.9", 5)

      assert {:blocked, %{scope: :email}} =
               LoginThrottle.check("staff@example.com", "198.51.100.9")

      assert LoginThrottle.check("other@example.com", "198.51.100.9") == :ok
    end
  end

  describe "clear_failures/1" do
    test "forgets an email's failures after a successful sign-in" do
      fail("staff@example.com", @ip, 4)
      assert LoginThrottle.failure_count(:email, "staff@example.com") == 4

      LoginThrottle.clear_failures("staff@example.com")

      assert LoginThrottle.failure_count(:email, "staff@example.com") == 0
      assert LoginThrottle.check("staff@example.com", @ip) == :ok
    end

    test "does not clear the IP's, so one valid account cannot reset the source" do
      for n <- 1..19, do: fail("victim#{n}@example.com", "198.51.100.9")
      fail("mine@example.com", "198.51.100.9")

      LoginThrottle.clear_failures("mine@example.com")

      # 19 others remain against the address.
      assert LoginThrottle.failure_count(:ip, "198.51.100.9") == 19
    end

    test "leaves other accounts' failures alone" do
      fail("staff@example.com", @ip, 3)
      fail("owner@example.com", @ip, 2)

      LoginThrottle.clear_failures("staff@example.com")

      assert LoginThrottle.failure_count(:email, "owner@example.com") == 2
    end
  end

  describe "prune/0" do
    test "removes attempts past the retention period but keeps recent history" do
      fail("staff@example.com", @ip, 4)
      age_oldest(3, 25 * 60)

      assert LoginThrottle.prune() == 3
      assert Repo.aggregate(FailedLoginAttempt, :count) == 1
    end

    test "recording a failure prunes as it goes, so the table does not grow forever" do
      fail("staff@example.com", @ip, 3)
      age(25 * 60)

      fail("staff@example.com", @ip, 1)

      # The three aged rows went with the new one's write.
      assert Repo.aggregate(FailedLoginAttempt, :count) == 1
    end

    test "keeps attempts that are outside the counting window but inside retention" do
      fail("staff@example.com", @ip, 3)
      age(60)

      assert LoginThrottle.prune() == 0
      assert Repo.aggregate(FailedLoginAttempt, :count) == 3
      # Kept for the record, but no longer counting against anyone.
      assert LoginThrottle.check("staff@example.com", @ip) == :ok
    end
  end

  describe "blocked_message/1" do
    test "says how long to wait without saying anything else" do
      message = LoginThrottle.blocked_message(%{retry_after_seconds: 540})

      assert message =~ "Too many failed sign-in attempts"
      assert message =~ "9 minutes"
      refute message =~ "email"
      refute message =~ "IP"
    end

    test "reads sensibly at the short end" do
      assert LoginThrottle.blocked_message(%{retry_after_seconds: 5}) =~ "a few seconds"
      assert LoginThrottle.blocked_message(%{retry_after_seconds: 90}) =~ "about a minute"
    end

    test "is the same whichever limit was hit" do
      by_email = LoginThrottle.blocked_message(%{scope: :email, retry_after_seconds: 300})
      by_ip = LoginThrottle.blocked_message(%{scope: :ip, retry_after_seconds: 300})

      assert by_email == by_ip
    end
  end
end
