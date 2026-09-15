defmodule RealinvoiceCloud.Repo.Migrations.CreateCreditNotes do
  use Ecto.Migration

  def change do
    create table(:credit_notes) do
      add :credit_note_no, :string, null: false
      add :date, :date, null: false

      # A credit note always corrects a specific invoice. Unlike an invoice's
      # customer, this is not optional: a credit with nothing to credit could
      # not be netted off anything, and would quietly skew every revenue figure
      # built on top of it.
      add :original_invoice_id, references(:invoices, on_delete: :restrict), null: false

      add :reason, :string

      add :subtotal, :decimal, precision: 14, scale: 2, null: false
      add :cgst, :decimal, precision: 14, scale: 2, null: false, default: 0
      add :sgst, :decimal, precision: 14, scale: 2, null: false, default: 0
      add :igst, :decimal, precision: 14, scale: 2, null: false, default: 0
      add :grand_total, :decimal, precision: 14, scale: 2, null: false

      add :store_node_id, :string, null: false
      add :created_by, :string

      add :node_id, references(:nodes, on_delete: :restrict)
      add :client_id, :string

      timestamps(type: :utc_datetime)
    end

    # Numbered per desk, like invoices: every desk starts its own sequence.
    create unique_index(:credit_notes, [:store_node_id, :credit_note_no])
    # The sync identity of a row: the desk, plus the id that desk gave it.
    create unique_index(:credit_notes, [:node_id, :client_id])
    # Netting an invoice, and the dashboard's per-day/per-desk aggregates.
    create index(:credit_notes, [:original_invoice_id])
    create index(:credit_notes, [:date])
    create index(:credit_notes, [:store_node_id, :date])

    create table(:credit_note_lines) do
      add :credit_note_id, references(:credit_notes, on_delete: :delete_all), null: false
      add :item_id, references(:items, on_delete: :restrict), null: false
      add :qty, :decimal, precision: 12, scale: 3, null: false
      add :rate, :decimal, precision: 14, scale: 2, null: false
      add :tax_rate, :decimal, precision: 5, scale: 2, null: false
      add :line_total, :decimal, precision: 14, scale: 2, null: false

      add :node_id, references(:nodes, on_delete: :restrict)
      add :client_id, :string

      timestamps(type: :utc_datetime)
    end

    create index(:credit_note_lines, [:credit_note_id])
    create index(:credit_note_lines, [:item_id])
    create unique_index(:credit_note_lines, [:node_id, :client_id])
  end
end
