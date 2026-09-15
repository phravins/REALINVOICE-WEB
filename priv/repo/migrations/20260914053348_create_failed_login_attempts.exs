defmodule RealinvoiceCloud.Repo.Migrations.CreateFailedLoginAttempts do
  use Ecto.Migration

  def change do
    create table(:failed_login_attempts) do
      # The email as submitted, trimmed and downcased. Recorded whether or not
      # an account exists, so a block never reveals which emails are real.
      add :email, :string, null: false

      # The peer address of the request. See the module docs for what this is
      # worth behind a proxy.
      add :ip, :string, null: false

      add :inserted_at, :utc_datetime_usec, null: false
    end

    # The two counting queries, each one index scan over a narrow time range.
    create index(:failed_login_attempts, [:email, :inserted_at])
    create index(:failed_login_attempts, [:ip, :inserted_at])

    # Pruning old rows scans by age alone.
    create index(:failed_login_attempts, [:inserted_at])
  end
end
