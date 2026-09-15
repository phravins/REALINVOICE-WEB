defmodule RealinvoiceCloud.Repo.Migrations.AddClientIdsForSync do
  use Ecto.Migration

  # The sync worker stamps every row it sends with an identifier it generated
  # locally and never reuses. Storing it here is what makes ingest idempotent:
  # a retried batch finds the existing row instead of inserting a second copy.
  #
  # Nullable, because rows that did not come from a desk (the sample data in
  # priv/repo/seeds.exs) have no client id. A plain unique index is right for
  # that: Postgres treats NULLs as distinct, so any number of rows may have none
  # while a real id can only ever appear once.
  def change do
    for table <- [:customers, :items, :invoices, :invoice_lines] do
      alter table(table) do
        add :client_id, :string
      end

      create unique_index(table, [:client_id])
    end
  end
end
