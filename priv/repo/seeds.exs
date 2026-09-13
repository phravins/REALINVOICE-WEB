# Seeds the one back-office account the app ships with.
#
# Public registration is disabled on purpose (this is an internal admin tool),
# so the first owner account is created here instead:
#
#     mix run priv/repo/seeds.exs
#
# It is idempotent — re-running it leaves an existing account alone rather than
# resetting its password. Override the defaults with environment variables:
#
#     ADMIN_EMAIL=ops@osworks.in ADMIN_PASSWORD='…' mix run priv/repo/seeds.exs
#
# The default password below is for local development only. Always pass
# ADMIN_PASSWORD when seeding anything that is not a throwaway database.

alias RealinvoiceCloud.Accounts

email = System.get_env("ADMIN_EMAIL") || "admin@realinvoice.local"
password = System.get_env("ADMIN_PASSWORD") || "realinvoice-dev-password"

case Accounts.get_user_by_email(email) do
  nil ->
    case Accounts.create_staff_user(%{email: email, password: password, role: "owner"}) do
      {:ok, user} ->
        IO.puts("Created owner account #{user.email}")

      {:error, changeset} ->
        IO.puts("Could not create #{email}:")

        Enum.each(changeset.errors, fn {field, {message, _}} ->
          IO.puts("  #{field} #{message}")
        end)

        System.halt(1)
    end

  user ->
    IO.puts("Owner account #{user.email} already exists, leaving it untouched")
end
