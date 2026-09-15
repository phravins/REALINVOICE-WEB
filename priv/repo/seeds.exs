# Seeds the back office: one staff account, plus sample billing data.
#
#     mix run priv/repo/seeds.exs
#
# Both halves are idempotent — re-running leaves existing data alone. To rebuild
# the sample billing data from scratch (it is discarded and regenerated, staff
# accounts are untouched):
#
#     RESEED=1 mix run priv/repo/seeds.exs
#
# Override the staff account with environment variables:
#
#     ADMIN_EMAIL=ops@osworks.in ADMIN_PASSWORD='…' mix run priv/repo/seeds.exs
#
# The default password below is for local development only. Always pass
# ADMIN_PASSWORD when seeding anything that is not a throwaway database.

alias RealinvoiceCloud.Accounts
alias RealinvoiceCloud.Billing

## Staff account ############################################################

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

## Sample billing data ######################################################

defmodule SampleBilling do
  @moduledoc """
  Builds a plausible few weeks of trading across two billing desks.

  This stands in for the ingest API until it exists. It is what proves the
  multi-desk reporting concept: two desks numbering their invoices
  independently (both start at RI-2026-0001), with revenue attributable to each.

  The GST arithmetic here belongs to the *desk*, not the cloud — it exists so
  the seeded figures are internally consistent and can be checked against what
  the invoice pages display. `RealinvoiceCloud.Billing` never recomputes it.
  """

  # Both desks trade from Tamil Nadu, so a Tamil Nadu customer is an
  # intra-state sale (CGST + SGST) and anyone else is inter-state (IGST).
  @home_state "Tamil Nadu"

  @nodes ~w(POS-01 POS-02)
  @payment_types ~w(Cash Card UPI Credit)
  @cashiers %{
    "POS-01" => ["Anitha R (till-1)", "Suresh K (till-2)"],
    "POS-02" => ["Divya M (till-1)"]
  }

  def run do
    # A fixed seed keeps the sample data reproducible: the same invoice
    # numbers, quantities and totals on every machine that runs the seeds.
    :rand.seed(:exsss, {101, 202, 303})

    customers = insert_customers()
    items = insert_items()
    invoices = insert_invoices(customers, items)
    credit_notes = insert_credit_notes(invoices)

    {customers, items, invoices, credit_notes}
  end

  defp insert_customers do
    [
      %{
        name: "Vaanavil Systems Pvt Ltd",
        gstin: "33AABCV1234M1Z7",
        place_of_supply: "Tamil Nadu",
        mobile: "+91 98400 11223",
        store_node_id: "POS-01"
      },
      %{
        name: "Nandhini Traders",
        gstin: "29AACCN5678K1Z3",
        place_of_supply: "Karnataka",
        mobile: "+91 98861 44556",
        store_node_id: "POS-01"
      },
      %{
        name: "Kaveri Infotech LLP",
        gstin: "33AAGCK9012P1Z9",
        place_of_supply: "Tamil Nadu",
        mobile: "+91 90031 77889",
        store_node_id: "POS-02"
      }
    ]
    |> Enum.map(&Billing.create_customer!/1)
  end

  defp insert_items do
    [
      %{
        item_code: "RK-42U-PRO",
        description: "42U Server Rack Pro",
        rate: "48500.00",
        tax_rate: "18.00",
        uom: "Nos",
        store_node_id: "POS-01"
      },
      %{
        item_code: "SW-ABCOS-ENT",
        description: "aBCOS Enterprise Lic",
        rate: "125000.00",
        tax_rate: "18.00",
        uom: "Lic",
        store_node_id: "POS-01"
      },
      %{
        item_code: "NW-CAT6-305",
        description: "Cat6 UTP Cable 305m Box",
        rate: "7850.00",
        tax_rate: "18.00",
        uom: "Box",
        store_node_id: "POS-01"
      },
      %{
        item_code: "PW-UPS-3KVA",
        description: "3KVA Online UPS",
        rate: "32400.00",
        tax_rate: "18.00",
        uom: "Nos",
        store_node_id: "POS-01"
      },
      %{
        item_code: "SV-AMC-YR",
        description: "Annual Maintenance Contract",
        rate: "18000.00",
        tax_rate: "18.00",
        uom: "Yr",
        store_node_id: "POS-02"
      },
      %{
        item_code: "AC-PDU-16A",
        description: "16A Rack PDU 8-way",
        rate: "4250.00",
        tax_rate: "18.00",
        uom: "Nos",
        store_node_id: "POS-02"
      }
    ]
    |> Enum.map(&Billing.create_item!/1)
  end

  defp insert_invoices(customers, items) do
    today = Date.utc_today()

    # Every desk numbers its own invoices from 0001, so the counter is per node.
    counters = Map.new(@nodes, &{&1, 0})

    {invoices, _counters} =
      today
      |> invoice_dates()
      |> Enum.reduce({[], counters}, fn {date, node}, {acc, counters} ->
        seq = Map.fetch!(counters, node) + 1
        invoice = insert_invoice(date, node, seq, customers, items)
        {[invoice | acc], Map.put(counters, node, seq)}
      end)

    Enum.reverse(invoices)
  end

  # A spread of 13 invoices: several today, several across the past week, and
  # the rest earlier in the current month — enough for the dashboard's "today"
  # and "month to date" figures to differ meaningfully.
  defp invoice_dates(today) do
    month_start = Date.beginning_of_month(today)

    in_month = fn date ->
      Date.compare(date, month_start) != :lt and Date.compare(date, today) != :gt
    end

    today_dates = [today, today, today]
    week_dates = for offset <- [1, 2, 3, 5], do: Date.add(today, -offset)
    month_dates = for offset <- [0, 2, 4, 6, 8, 10], do: Date.add(month_start, offset)

    (today_dates ++ week_dates ++ month_dates)
    |> Enum.filter(in_month)
    |> Enum.sort(Date)
    # Alternate desks so both have invoices on overlapping days.
    |> Enum.with_index()
    |> Enum.map(fn {date, index} -> {date, Enum.at(@nodes, rem(index, length(@nodes)))} end)
  end

  defp insert_invoice(date, node, seq, customers, items) do
    node_items = Enum.filter(items, &(&1.store_node_id == node))
    node_customers = Enum.filter(customers, &(&1.store_node_id == node))

    # Every fourth invoice is a counter sale with no customer record, which is
    # ordinary at a billing desk and exercises the nullable customer_id.
    customer = if rem(seq, 4) == 0, do: nil, else: Enum.random(node_customers)

    lines =
      node_items
      |> Enum.take_random(Enum.random(1..min(3, length(node_items))))
      |> Enum.map(&build_line/1)

    subtotal = sum(lines, & &1.line_total)
    tax_total = lines |> Enum.map(&line_tax/1) |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

    {cgst, sgst, igst} = split_tax(tax_total, customer)

    {:ok, invoice} =
      Billing.create_invoice(%{
        invoice_no: "RI-2026-" <> String.pad_leading(to_string(seq), 4, "0"),
        date: date,
        customer_id: customer && customer.id,
        subtotal: subtotal,
        cgst: cgst,
        sgst: sgst,
        igst: igst,
        grand_total: Decimal.add(subtotal, tax_total),
        payment_type: Enum.random(@payment_types),
        store_node_id: node,
        created_by: Enum.random(Map.fetch!(@cashiers, node)),
        lines: lines
      })

    invoice
  end

  # A few corrections, because real trading has them: a returned item here, a
  # wrong quantity there. Two are dated today so the dashboard's "revenue
  # today" is visibly net of them, and one sits earlier in the month so the
  # month-to-date figure differs from the day's.
  #
  # A credit note is dated when it is raised, not when the invoice was — so an
  # older invoice corrected today reduces today's takings, not that day's.
  @credit_reasons %{
    0 => "One unit returned unopened",
    1 => "Billed at the wrong rate, difference credited",
    2 => "Damaged in transit, replaced free of charge"
  }

  defp insert_credit_notes(invoices) do
    today = Date.utc_today()

    # The latest invoice at each desk, corrected today, plus the earliest
    # POS-01 invoice corrected a few days after it was raised.
    latest_per_node =
      @nodes
      |> Enum.map(fn node ->
        invoices
        |> Enum.filter(&(&1.store_node_id == node))
        |> List.last()
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&{&1, today})

    earlier =
      case Enum.filter(invoices, &(&1.store_node_id == "POS-01")) do
        [first | _] -> [{first, earliest_credit_date(first.date, today)}]
        [] -> []
      end

    (earlier ++ latest_per_node)
    |> Enum.with_index()
    |> Enum.reduce({[], Map.new(@nodes, &{&1, 0})}, fn {{invoice, date}, index},
                                                       {acc, counters} ->
      seq = Map.fetch!(counters, invoice.store_node_id) + 1
      note = insert_credit_note(invoice, date, seq, index)
      {[note | acc], Map.put(counters, invoice.store_node_id, seq)}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # Two days after the invoice, or today if that would be in the future.
  defp earliest_credit_date(invoice_date, today) do
    candidate = Date.add(invoice_date, 2)
    if Date.compare(candidate, today) == :gt, do: today, else: candidate
  end

  defp insert_credit_note(invoice, date, seq, index) do
    node = invoice.store_node_id

    # Credit one unit of the invoice's first line — a returned item, not a
    # cancelled invoice. Figures are stored positive: the document subtracts.
    line = hd(invoice.lines)

    credited = %{
      item_id: line.item_id,
      qty: Decimal.new(1),
      rate: line.rate,
      tax_rate: line.tax_rate,
      line_total: money(line.rate)
    }

    subtotal = credited.line_total
    tax_total = line_tax(credited)

    # The credit follows the invoice's own tax regime, so an inter-state sale
    # is credited under IGST and an intra-state one under CGST + SGST.
    {cgst, sgst, igst} =
      if Decimal.gt?(invoice.igst, 0) do
        {Decimal.new("0.00"), Decimal.new("0.00"), tax_total}
      else
        half = tax_total |> Decimal.div(2) |> money()
        {half, Decimal.sub(tax_total, half), Decimal.new("0.00")}
      end

    {:ok, note} =
      Billing.create_credit_note(%{
        credit_note_no: "CN-2026-" <> String.pad_leading(to_string(seq), 4, "0"),
        date: date,
        original_invoice_id: invoice.id,
        reason: Map.fetch!(@credit_reasons, rem(index, map_size(@credit_reasons))),
        subtotal: subtotal,
        cgst: cgst,
        sgst: sgst,
        igst: igst,
        grand_total: Decimal.add(subtotal, tax_total),
        store_node_id: node,
        created_by: Enum.random(Map.fetch!(@cashiers, node)),
        lines: [credited]
      })

    note
  end

  defp build_line(item) do
    qty = Decimal.new(Enum.random(1..4))

    %{
      item_id: item.id,
      qty: qty,
      rate: item.rate,
      tax_rate: item.tax_rate,
      line_total: money(Decimal.mult(qty, item.rate))
    }
  end

  defp line_tax(line) do
    line.line_total
    |> Decimal.mult(line.tax_rate)
    |> Decimal.div(100)
    |> money()
  end

  # Intra-state tax is split evenly between CGST and SGST; giving SGST the
  # remainder keeps the two halves summing to the total exactly, even when the
  # total is an odd number of paise.
  defp split_tax(tax_total, customer) do
    zero = Decimal.new("0.00")

    if intra_state?(customer) do
      cgst = tax_total |> Decimal.div(2) |> money()
      {cgst, Decimal.sub(tax_total, cgst), zero}
    else
      {zero, zero, tax_total}
    end
  end

  # A counter sale with no customer record is billed where it stands, so it is
  # always intra-state.
  defp intra_state?(nil), do: true
  defp intra_state?(customer), do: customer.place_of_supply == @home_state

  defp sum(rows, fun) do
    Enum.reduce(rows, Decimal.new("0.00"), fn row, acc -> Decimal.add(acc, fun.(row)) end)
  end

  defp money(decimal), do: Decimal.round(decimal, 2)
end

reseed? = System.get_env("RESEED") in ~w(1 true yes)

summary = fn {customers, items, invoices, credit_notes} ->
  "#{length(customers)} customers, #{length(items)} items, " <>
    "#{length(invoices)} invoices, #{length(credit_notes)} credit notes"
end

cond do
  reseed? ->
    Billing.delete_all_billing_data!()
    IO.puts("Rebuilt sample billing data: " <> summary.(SampleBilling.run()))

  Billing.any_invoices?() ->
    IO.puts("Sample billing data already present, leaving it untouched (RESEED=1 to rebuild)")

  true ->
    IO.puts("Created sample billing data: " <> summary.(SampleBilling.run()))
end
