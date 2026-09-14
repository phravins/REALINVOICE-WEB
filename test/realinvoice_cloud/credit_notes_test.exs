defmodule RealinvoiceCloud.CreditNotesTest do
  use RealinvoiceCloud.DataCase, async: true

  import RealinvoiceCloud.BillingFixtures

  alias RealinvoiceCloud.Billing
  alias RealinvoiceCloud.Billing.CreditNote

  describe "CreditNote.changeset/2" do
    test "requires the number, date, original invoice, node and every amount" do
      errors = errors_on(CreditNote.changeset(%CreditNote{}, %{}))

      for field <- [
            :credit_note_no,
            :date,
            :original_invoice_id,
            :store_node_id,
            :subtotal,
            :cgst,
            :sgst,
            :igst,
            :grand_total
          ] do
        assert errors[field] == ["can't be blank"], "expected #{field} to be required"
      end
    end

    test "requires at least one line" do
      assert %{lines: ["can't be blank"]} = errors_on(CreditNote.changeset(%CreditNote{}, %{}))
    end

    test "rejects both tax regimes at once" do
      invoice = invoice_fixture()
      item = item_fixture()

      changeset =
        CreditNote.changeset(%CreditNote{}, %{
          credit_note_no: "CN-2026-0001",
          date: Date.utc_today(),
          original_invoice_id: invoice.id,
          subtotal: "100.00",
          cgst: "9.00",
          sgst: "9.00",
          igst: "18.00",
          grand_total: "118.00",
          store_node_id: "POS-01",
          lines: [
            %{item_id: item.id, qty: "1", rate: "100", tax_rate: "18", line_total: "100.00"}
          ]
        })

      assert %{igst: ["cannot be charged alongside CGST or SGST"]} = errors_on(changeset)
    end

    test "two desks may issue the same credit note number, one desk may not" do
      invoice_a = invoice_fixture(%{store_node_id: "POS-01"})
      invoice_b = invoice_fixture(%{store_node_id: "POS-02"})

      credit_note_fixture(%{credit_note_no: "CN-0001", original_invoice_id: invoice_a.id})

      assert %CreditNote{} =
               credit_note_fixture(%{
                 credit_note_no: "CN-0001",
                 original_invoice_id: invoice_b.id,
                 store_node_id: "POS-02"
               })

      item = item_fixture()

      assert {:error, changeset} =
               Billing.create_credit_note(%{
                 credit_note_no: "CN-0001",
                 date: Date.utc_today(),
                 original_invoice_id: invoice_a.id,
                 subtotal: "1.00",
                 cgst: "0.00",
                 sgst: "0.00",
                 igst: "0.00",
                 grand_total: "1.00",
                 store_node_id: "POS-01",
                 lines: [
                   %{item_id: item.id, qty: "1", rate: "1", tax_rate: "0", line_total: "1.00"}
                 ]
               })

      assert %{store_node_id: ["already exists for this billing desk"]} = errors_on(changeset)
    end

    test "stores the desk's figures exactly as sent" do
      invoice = invoice_fixture()
      item = item_fixture()

      {:ok, note} =
        Billing.create_credit_note(%{
          credit_note_no: "CN-2026-0001",
          date: ~D[2026-09-14],
          original_invoice_id: invoice.id,
          reason: "Returned unopened",
          subtotal: "200.00",
          cgst: "18.00",
          sgst: "18.00",
          igst: "0.00",
          grand_total: "236.00",
          store_node_id: "POS-01",
          created_by: "Anitha R (till-1)",
          lines: [
            %{item_id: item.id, qty: "2", rate: "100.00", tax_rate: "18.00", line_total: "200.00"}
          ]
        })

      assert Decimal.equal?(note.grand_total, Decimal.new("236.00"))
      assert note.reason == "Returned unopened"
      assert note.created_by == "Anitha R (till-1)"
    end

    test "keeps its figures positive — the document subtracts, not the numbers" do
      note = credit_note_fixture()

      assert Decimal.positive?(note.grand_total)
      assert Enum.all?(note.lines, &Decimal.positive?(&1.line_total))
    end
  end

  describe "create_credit_note/1" do
    test "broadcasts the new credit note" do
      Billing.subscribe()
      note = credit_note_fixture()

      # Pinned to this note: the topic is shared, so a concurrently running
      # test's credit note may be sitting in the mailbox ahead of ours.
      id = note.id
      assert_receive {:credit_note_created, %CreditNote{id: ^id} = broadcast}
      assert [%{item: %{}}] = broadcast.lines
    end
  end

  describe "netting an invoice" do
    test "an uncredited invoice nets to its grand total" do
      invoice_fixture(%{grand_total: "1000.00"})

      assert [listed] = Billing.list_invoices()
      refute Billing.credited?(listed)
      assert Decimal.equal?(Billing.net_total(listed), Decimal.new("1000.00"))
      assert listed.credit_note_count == 0
    end

    test "a credited invoice nets down by what was credited" do
      invoice = invoice_fixture(%{grand_total: "1000.00"})
      credit_note_fixture(%{original_invoice_id: invoice.id, grand_total: "250.00"})

      assert [listed] = Billing.list_invoices()
      assert Billing.credited?(listed)
      assert listed.credit_note_count == 1
      assert Decimal.equal?(Billing.credited_total(listed), Decimal.new("250.00"))
      assert Decimal.equal?(Billing.net_total(listed), Decimal.new("750.00"))
    end

    test "several credit notes against one invoice all count" do
      invoice = invoice_fixture(%{grand_total: "1000.00"})
      credit_note_fixture(%{original_invoice_id: invoice.id, grand_total: "100.00"})
      credit_note_fixture(%{original_invoice_id: invoice.id, grand_total: "150.00"})

      assert [listed] = Billing.list_invoices()
      assert listed.credit_note_count == 2
      assert Decimal.equal?(Billing.net_total(listed), Decimal.new("750.00"))
    end

    test "a credit against one invoice does not touch another" do
      credited = invoice_fixture(%{invoice_no: "A", grand_total: "1000.00"})
      untouched = invoice_fixture(%{invoice_no: "B", grand_total: "500.00"})
      credit_note_fixture(%{original_invoice_id: credited.id, grand_total: "250.00"})

      by_no = Map.new(Billing.list_invoices(), &{&1.invoice_no, &1})

      assert Decimal.equal?(Billing.net_total(by_no["A"]), Decimal.new("750.00"))
      assert Decimal.equal?(Billing.net_total(by_no["B"]), Decimal.new("500.00"))
      assert by_no["B"].credit_note_count == 0
      assert untouched.id == by_no["B"].id
    end

    test "get_invoice!/1 carries the notes, their lines and the same aggregates" do
      invoice = invoice_fixture(%{grand_total: "1000.00"})
      credit_note_fixture(%{original_invoice_id: invoice.id, grand_total: "250.00"})

      loaded = Billing.get_invoice!(invoice.id)

      assert [note] = loaded.credit_notes
      assert [%{item: %{}}] = note.lines
      assert loaded.credit_note_count == 1
      assert Decimal.equal?(Billing.net_total(loaded), Decimal.new("750.00"))
    end
  end

  describe "the credited filter" do
    setup do
      credited = invoice_fixture(%{invoice_no: "CREDITED", grand_total: "1000.00"})
      clean = invoice_fixture(%{invoice_no: "CLEAN", grand_total: "500.00"})
      credit_note_fixture(%{original_invoice_id: credited.id, grand_total: "100.00"})

      %{credited: credited, clean: clean}
    end

    test "credited returns only corrected invoices", %{credited: credited} do
      assert [found] = Billing.list_invoices(%{"credited" => "credited"})
      assert found.id == credited.id
    end

    test "uncredited returns only the rest", %{clean: clean} do
      assert [found] = Billing.list_invoices(%{"credited" => "uncredited"})
      assert found.id == clean.id
    end

    test "an unrecognised value is ignored rather than hiding everything" do
      assert length(Billing.list_invoices(%{"credited" => ""})) == 2
      assert length(Billing.list_invoices(%{"credited" => "nonsense"})) == 2
    end

    test "combines with the other filters", %{credited: credited} do
      assert [found] = Billing.list_invoices(%{"credited" => "credited", "node" => "POS-01"})
      assert found.id == credited.id
      assert Billing.list_invoices(%{"credited" => "credited", "node" => "POS-99"}) == []
    end
  end

  describe "dashboard_metrics/1 netting" do
    test "revenue is net of the day's credit notes" do
      today = ~D[2026-09-14]
      invoice = invoice_fixture(%{date: today, grand_total: "1000.00"})
      credit_note_fixture(%{original_invoice_id: invoice.id, date: today, grand_total: "250.00"})

      metrics = Billing.dashboard_metrics(today)

      assert Decimal.equal?(metrics.today.revenue, Decimal.new("750.00"))
      assert Decimal.equal?(metrics.today.gross_revenue, Decimal.new("1000.00"))
      assert Decimal.equal?(metrics.today.credited, Decimal.new("250.00"))
      assert metrics.today.count == 1
      assert metrics.today.credit_note_count == 1
    end

    test "a credit note counts on its own date, not the invoice's" do
      invoice = invoice_fixture(%{date: ~D[2026-09-01], grand_total: "1000.00"})

      credit_note_fixture(%{
        original_invoice_id: invoice.id,
        date: ~D[2026-09-14],
        grand_total: "250.00"
      })

      # The day the invoice was raised is untouched …
      first = Billing.dashboard_metrics(~D[2026-09-01])
      assert Decimal.equal?(first.today.revenue, Decimal.new("1000.00"))

      # … the day the credit was raised carries it.
      second = Billing.dashboard_metrics(~D[2026-09-14])
      assert Decimal.equal?(second.today.revenue, Decimal.new("-250.00"))

      # And the month to date nets out to the difference.
      assert Decimal.equal?(second.month.revenue, Decimal.new("750.00"))
    end

    test "revenue by node nets per desk" do
      today = ~D[2026-09-14]
      one = invoice_fixture(%{date: today, store_node_id: "POS-01", grand_total: "1000.00"})
      invoice_fixture(%{date: today, store_node_id: "POS-02", grand_total: "400.00"})

      credit_note_fixture(%{
        original_invoice_id: one.id,
        date: today,
        store_node_id: "POS-01",
        grand_total: "250.00"
      })

      assert [pos1, pos2] = Billing.dashboard_metrics(today).by_node

      assert pos1.node == "POS-01"
      assert Decimal.equal?(pos1.revenue, Decimal.new("750.00"))
      assert Decimal.equal?(pos1.credited, Decimal.new("250.00"))
      assert pos1.credit_note_count == 1

      assert pos2.node == "POS-02"
      assert Decimal.equal?(pos2.revenue, Decimal.new("400.00"))
      assert Decimal.equal?(pos2.credited, Decimal.new("0"))
    end

    test "a desk that only issued credits today still appears" do
      today = ~D[2026-09-14]
      invoice = invoice_fixture(%{date: ~D[2026-09-01], store_node_id: "POS-05"})

      credit_note_fixture(%{
        original_invoice_id: invoice.id,
        date: today,
        store_node_id: "POS-05",
        grand_total: "300.00"
      })

      assert [row] = Billing.dashboard_metrics(today).by_node
      assert row.node == "POS-05"
      assert row.count == 0
      assert Decimal.equal?(row.revenue, Decimal.new("-300.00"))
    end

    test "with no credit notes at all, revenue is the gross" do
      today = ~D[2026-09-14]
      invoice_fixture(%{date: today, grand_total: "1000.00"})

      metrics = Billing.dashboard_metrics(today)

      assert Decimal.equal?(metrics.today.revenue, metrics.today.gross_revenue)
      assert Decimal.equal?(metrics.today.credited, Decimal.new("0"))
    end
  end

  describe "list_credit_notes_for_invoice/1" do
    test "returns the notes against one invoice, newest first" do
      invoice = invoice_fixture()

      credit_note_fixture(%{
        original_invoice_id: invoice.id,
        date: ~D[2026-09-01],
        credit_note_no: "CN-OLD"
      })

      credit_note_fixture(%{
        original_invoice_id: invoice.id,
        date: ~D[2026-09-14],
        credit_note_no: "CN-NEW"
      })

      credit_note_fixture(%{credit_note_no: "CN-OTHER"})

      assert [%{credit_note_no: "CN-NEW"}, %{credit_note_no: "CN-OLD"}] =
               Billing.list_credit_notes_for_invoice(invoice.id)
    end
  end
end
