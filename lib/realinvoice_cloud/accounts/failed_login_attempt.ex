defmodule RealinvoiceCloud.Accounts.FailedLoginAttempt do
  @moduledoc """
  One failed password sign-in.

  Rows are counted by `RealinvoiceCloud.Accounts.LoginThrottle` and pruned by
  it; nothing else writes here. A row is recorded whether or not the email
  belongs to a real account, so that being blocked reveals nothing about who
  has an account.
  """
  use Ecto.Schema

  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "failed_login_attempts" do
    field :email, :string
    field :ip, :string

    timestamps()
  end
end
