defmodule RealinvoiceCloud.BillingTest do
  use RealinvoiceCloud.DataCase, async: true

  import RealinvoiceCloud.BillingFixtures

  alias RealinvoiceCloud.Billing
  alias RealinvoiceCloud.Billing.Customer
  alias RealinvoiceCloud.Billing.Invoice
  alias RealinvoiceCloud.Billing.InvoiceLine
  alias RealinvoiceCloud.Billing.Item

  describe "Customer.changeset/2" do
    test "requires a name and an originating node" do
      changeset = Customer.changeset(%Customer{}, %{})

      assert %{name: ["can't be blank"], store_node_id: ["can't be blank"]} =
               errors_on(changeset)
    end

    test "rejects a malformed GSTIN" do
      changeset =
        Customer.changeset(%Customer{}, %{name: "X", store_node_id: "POS-01", gstin: "nope"})

      assert %{gstin: ["is not a valid GSTIN"]} = errors_on(changeset)
    end

    test "accepts and normalises a valid GSTIN" do
      changeset =
        Customer.changeset(%Customer{}, %{
          name: "X",
          store_node_id: "POS-01",
          gstin: " 33aabcv1234m1z7 "
        })

      assert changeset.valid?
      assert get_change(changeset, :gstin) == "33AABCV1234M1Z7"
    end

    test "a customer without a GSTIN is fine" do
      assert Customer.changeset(%Customer{}, %{name: "Counter", store_node_id: "POS-01"}).valid?
    end
  end

  describe "Item.changeset/2" do
    test "requires a code, rate, tax rate and node" do
      errors = errors_on(Item.changeset(%Item{}, %{}))

      assert errors.item_code == ["can't be blank"]
      assert errors.rate == ["can't be blank"]
      assert errors.tax_rate == ["can't be blank"]
      assert errors.store_node_id == ["can't be blank"]
    end

    test "rejects a negative rate and an impossible tax rate" do
      errors =
        errors_on(
          Item.changeset(%Item{}, %{
            item_code: "X",
            store_node_id: "POS-01",
            rate: "-1",
            tax_rate: "120"
          })
        )

      assert errors.rate == ["must be greater than or equal to 0"]
      assert errors.tax_rate == ["must be less than or equal to 100"]
    end

    test "a zero rate is allowed, for a bundled line" do
      assert Item.changeset(%Item{}, %{
               item_code: "FREE",
               store_node_id: "POS-01",
               rate: "0",
               tax_rate: "0"
             }).valid?
    end

    test "the same item code may exist on a different desk but not twice on one" do
      item_fixture(%{item_code: "RK-42U-PRO", store_node_id: "POS-01"})

      assert %Item{} = item_fixture(%{item_code: "RK-42U-PRO", store_node_id: "POS-02"})

      assert_raise Ecto.InvalidChangesetError, fn ->
        item_fixture(%{item_code: "RK-42U-PRO", store_node_id: "POS-01"})
      end
    end
  end

  describe "InvoiceLine.changeset/2" do
    test "rejects a zero or negative quantity" do
      for quantity <- ["0", "-2"] do
        errors =
          errors_on(
            InvoiceLine.changeset(%InvoiceLine{}, %{
              item_id: 1,
              qty: quantity,
              rate: "10",
              tax_rate: "18",
              line_total: "0"
            })
          )

        assert errors.qty == ["must be greater than 0"]
      end
    end
  end

  describe "Invoice.changeset/2" do
    test "requires the number, date, payment type, node and every amount" do
      errors = errors_on(Invoice.changeset(%Invoice{}, %{}))

      for field <- [
            :invoice_no,
            :date,
            :payment_type,
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
      assert %{lines: ["can't be blank"]} = errors_on(Invoice.changeset(%Invoice{}, %{}))
    end

    test "rejects an invoice charging both tax regimes at once" do
      item = item_fixture()

      changeset =
        Invoice.changeset(%Invoice{}, %{
          invoice_no: "RI-2026-0001",
          date: Date.utc_today(),
          subtotal: "100.00",
          cgst: "9.00",
          sgst: "9.00",
          igst: "18.00",
          grand_total: "118.00",
          payment_type: "Cash",
          store_node_id: "POS-01",
          lines: [
            %{item_id: item.id, qty: "1", rate: "100", tax_rate: "18", line_total: "100.00"}
          ]
        })

      assert %{igst: ["cannot be charged alongside CGST or SGST"]} = errors_on(changeset)
    end

    test "two desks may issue the same invoice number, one desk may not" do
      invoice_fixture(%{invoice_no: "RI-2026-0001", store_node_id: "POS-01"})

      assert %Invoice{} = invoice_fixture(%{invoice_no: "RI-2026-0001", store_node_id: "POS-02"})

      item = item_fixture()

      assert {:error, changeset} =
               Billing.create_invoice(%{
                 invoice_no: "RI-2026-0001",
                 date: Date.utc_today(),
                 subtotal: "1.00",
                 cgst: "0.00",
                 sgst: "0.00",
                 igst: "0.00",
                 grand_total: "1.00",
                 payment_type: "Cash",
                 store_node_id: "POS-01",
                 lines: [
                   %{item_id: item.id, qty: "1", rate: "1", tax_rate: "0", line_total: "1.00"}
                 ]
               })

      assert %{store_node_id: ["already exists for this billing desk"]} = errors_on(changeset)
    end

    test "an invoice with no customer is accepted, as a counter sale" do
      invoice = invoice_fixture(%{customer_id: nil})
      assert is_nil(Billing.get_invoice!(invoice.id).customer)
    end
  end

  describe "create_invoice/1" do
    test "stores the desk's figures exactly as sent, without recomputing them" do
      item = item_fixture(%{rate: "100.00", tax_rate: "18.00"})

      # Deliberately inconsistent arithmetic: the desk is the authority, so the
      # back office must store this rather than "correcting" it.
      {:ok, invoice} =
        Billing.create_invoice(%{
          invoice_no: "RI-2026-9001",
          date: ~D[2026-09-13],
          subtotal: "200.00",
          cgst: "1.00",
          sgst: "2.00",
          igst: "0.00",
          grand_total: "999.99",
          payment_type: "Cash",
          store_node_id: "POS-01",
          lines: [
            %{item_id: item.id, qty: "2", rate: "100.00", tax_rate: "18.00", line_total: "200.00"}
          ]
        })

      assert Decimal.equal?(invoice.grand_total, Decimal.new("999.99"))
      assert Decimal.equal?(invoice.cgst, Decimal.new("1.00"))
    end

    test "broadcasts the new invoice to subscribers" do
      Billing.subscribe()
      invoice = invoice_fixture()

      # Pinned to this invoice: the topic is shared, so a concurrently running
      # test's invoice may be sitting in the mailbox ahead of ours.
      id = invoice.id
      assert_receive {:invoice_created, %Invoice{id: ^id} = broadcast}
      # Broadcast invoices arrive ready to render, associations and all.
      assert [%InvoiceLine{item: %Item{}}] = broadcast.lines
    end
  end

  describe "list_invoices/1" do
    setup do
      tn = customer_fixture(%{name: "Vaanavil Systems", place_of_supply: "Tamil Nadu"})

      today =
        invoice_fixture(%{invoice_no: "RI-2026-0001", customer_id: tn.id, date: ~D[2026-09-13]})

      older = invoice_fixture(%{invoice_no: "RI-2026-0002", date: ~D[2026-09-01]})
      other = invoice_fixture(%{invoice_no: "RI-2026-0003", store_node_id: "POS-02"})

      %{today: today, older: older, other: other, customer: tn}
    end

    test "returns every invoice, newest first", %{today: today, older: older} do
      numbers = Enum.map(Billing.list_invoices(), & &1.invoice_no)

      assert length(numbers) == 3

      assert Enum.find_index(numbers, &(&1 == today.invoice_no)) <
               Enum.find_index(numbers, &(&1 == older.invoice_no))
    end

    test "filters by node", %{other: other} do
      assert [found] = Billing.list_invoices(%{"node" => "POS-02"})
      assert found.id == other.id
    end

    test "filters by date range", %{older: older} do
      assert [found] =
               Billing.list_invoices(%{"from" => "2026-08-01", "to" => "2026-09-01"})

      assert found.id == older.id
    end

    test "accepts Date structs as well as ISO strings", %{older: older} do
      assert [found] = Billing.list_invoices(%{from: ~D[2026-08-01], to: ~D[2026-09-01]})
      assert found.id == older.id
    end

    test "searches by invoice number", %{today: today} do
      assert [found] = Billing.list_invoices(%{"q" => "0001"})
      assert found.id == today.id
    end

    test "searches by customer name", %{today: today} do
      assert [found] = Billing.list_invoices(%{"q" => "vaanavil"})
      assert found.id == today.id
    end

    test "ignores blank filter values" do
      assert length(Billing.list_invoices(%{"q" => "", "node" => "", "from" => ""})) == 3
    end

    test "treats LIKE wildcards in a search as literal text" do
      assert Billing.list_invoices(%{"q" => "%"}) == []
    end

    test "combines filters", %{other: other} do
      assert [found] = Billing.list_invoices(%{"node" => "POS-02", "q" => "0003"})
      assert found.id == other.id
      assert Billing.list_invoices(%{"node" => "POS-01", "q" => "0003"}) == []
    end
  end

  describe "matches_filters?/2" do
    test "reports whether an invoice belongs in a filtered view" do
      invoice = invoice_fixture(%{store_node_id: "POS-01", invoice_no: "RI-2026-0042"})

      assert Billing.matches_filters?(invoice, %{"node" => "POS-01"})
      refute Billing.matches_filters?(invoice, %{"node" => "POS-02"})
      assert Billing.matches_filters?(invoice, %{"q" => "0042"})
      refute Billing.matches_filters?(invoice, %{"q" => "nothing"})
      assert Billing.matches_filters?(invoice, %{})
    end
  end

  describe "list_store_nodes/0" do
    test "reports the distinct desks that have sent invoices" do
      invoice_fixture(%{store_node_id: "POS-02"})
      invoice_fixture(%{store_node_id: "POS-01"})
      invoice_fixture(%{store_node_id: "POS-01"})

      assert Billing.list_store_nodes() == ["POS-01", "POS-02"]
    end
  end

  describe "list_customers/1 and list_items/1" do
    test "search customers by name, GSTIN and mobile" do
      customer_fixture(%{
        name: "Nandhini Traders",
        gstin: "29AACCN5678K1Z3",
        mobile: "9886144556"
      })

      customer_fixture(%{name: "Kaveri Infotech", gstin: "33AAGCK9012P1Z9", mobile: "9003177889"})

      assert [%{name: "Nandhini Traders"}] = Billing.list_customers(%{"q" => "nandhini"})
      assert [%{name: "Nandhini Traders"}] = Billing.list_customers(%{"q" => "29AACCN"})
      assert [%{name: "Kaveri Infotech"}] = Billing.list_customers(%{"q" => "9003177889"})
      assert length(Billing.list_customers()) == 2
    end

    test "search items by code and description, and filter by node" do
      item_fixture(%{item_code: "RK-42U-PRO", description: "42U Server Rack Pro"})

      item_fixture(%{
        item_code: "SV-AMC-YR",
        description: "Annual Maintenance Contract",
        store_node_id: "POS-02"
      })

      assert [%{item_code: "RK-42U-PRO"}] = Billing.list_items(%{"q" => "42u server"})
      assert [%{item_code: "SV-AMC-YR"}] = Billing.list_items(%{"q" => "amc"})
      assert [%{item_code: "SV-AMC-YR"}] = Billing.list_items(%{"node" => "POS-02"})
    end
  end

  describe "dashboard_metrics/1" do
    test "adds up the day, the month to date and each desk" do
      today = ~D[2026-09-13]

      # today
      invoice_fixture(%{date: today, store_node_id: "POS-01", grand_total: "1000.00"})
      invoice_fixture(%{date: today, store_node_id: "POS-01", grand_total: "500.00"})
      invoice_fixture(%{date: today, store_node_id: "POS-02", grand_total: "250.00"})
      # earlier in the month
      invoice_fixture(%{date: ~D[2026-09-02], store_node_id: "POS-01", grand_total: "99.00"})
      # last month, so outside both windows
      invoice_fixture(%{date: ~D[2026-08-30], store_node_id: "POS-01", grand_total: "10000.00"})

      metrics = Billing.dashboard_metrics(today)

      assert metrics.today.count == 3
      assert Decimal.equal?(metrics.today.revenue, Decimal.new("1750.00"))

      assert metrics.month.count == 4
      assert Decimal.equal?(metrics.month.revenue, Decimal.new("1849.00"))

      assert [pos1, pos2] = metrics.by_node
      assert pos1.node == "POS-01"
      assert pos1.count == 2
      assert Decimal.equal?(pos1.revenue, Decimal.new("1500.00"))
      assert pos2.node == "POS-02"
      assert Decimal.equal?(pos2.revenue, Decimal.new("250.00"))
    end

    test "is all zeroes with no invoices at all" do
      metrics = Billing.dashboard_metrics(~D[2026-09-13])

      assert metrics.today.count == 0
      assert Decimal.equal?(Decimal.new(metrics.today.revenue), Decimal.new(0))
      assert metrics.by_node == []
      assert is_nil(metrics.last_invoice_at)
      refute Billing.any_invoices?()
    end
  end
end
