defmodule RealinvoiceCloud.Repo.Migrations.CreateInvoiceLines do
  use Ecto.Migration

  def change do
    create table(:invoice_lines) do
      add :invoice_id, references(:invoices, on_delete: :delete_all), null: false
      add :item_id, references(:items, on_delete: :restrict), null: false
      add :qty, :decimal, precision: 12, scale: 3, null: false
      add :rate, :decimal, precision: 14, scale: 2, null: false
      add :tax_rate, :decimal, precision: 5, scale: 2, null: false
      add :line_total, :decimal, precision: 14, scale: 2, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:invoice_lines, [:invoice_id])
    create index(:invoice_lines, [:item_id])
  end
end
