defmodule RealinvoiceCloud.Repo do
  use Ecto.Repo,
    otp_app: :realinvoice_cloud,
    adapter: Ecto.Adapters.Postgres
end
