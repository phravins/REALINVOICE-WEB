defmodule RealinvoiceCloud.Repo.Migrations.CreateInvoices do
  use Ecto.Migration

  def change do
    create table(:invoices) do
      add :invoice_no, :string, null: false
      add :date, :date, null: false

      # Nullable: a counter sale with no customer record is a normal thing for a
      # billing desk, and rejecting those on ingest would lose real invoices.
      add :customer_id, references(:customers, on_delete: :restrict)

      add :subtotal, :decimal, precision: 14, scale: 2, null: false
      add :cgst, :decimal, precision: 14, scale: 2, null: false, default: 0
      add :sgst, :decimal, precision: 14, scale: 2, null: false, default: 0
      add :igst, :decimal, precision: 14, scale: 2, null: false, default: 0
      add :grand_total, :decimal, precision: 14, scale: 2, null: false

      add :payment_type, :string, null: false
      add :store_node_id, :string, null: false

      # Mirrors the desktop app's created_by_user_id, but as a plain label:
      # the cloud has no knowledge of a desk's local cashier accounts, so it
      # stores whatever the desk sends rather than resolving it to a user.
      add :created_by, :string

      timestamps(type: :utc_datetime)
    end

    # Each desk numbers its own invoices, so every desk starts again at
    # RI-2026-0001. The number is only unique within a desk.
    create unique_index(:invoices, [:store_node_id, :invoice_no])
    create index(:invoices, [:date])
    create index(:invoices, [:customer_id])
    create index(:invoices, [:store_node_id, :date])
  end
end
