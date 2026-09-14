defmodule RealinvoiceCloud.Billing do
  @moduledoc """
  Reading and writing the billing data synced up from the desktop app.

  Everything in here is currently read-only from the back office's point of
  view: rows arrive from a billing desk (today only via `priv/repo/seeds.exs`,
  later via the ingest API) and the back office reports on them. There is
  deliberately no update or delete API — who owns editing this data, the cloud
  or the desk, is an open question and guessing at it now would be the wrong
  kind of commitment.

  ## Live updates

  `create_invoice/1` broadcasts on the `"billing:invoices"` topic, and
  `subscribe/0` joins it. The invoice list subscribes on mount, so once ingest
  starts writing invoices through this function they will appear in an open
  browser without a refresh. Nothing broadcasts in production yet — the path is
  exercised by the tests in `test/realinvoice_cloud/billing_test.exs` and
  `test/realinvoice_cloud_web/live/invoice_live_test.exs`.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Phoenix.PubSub
  alias RealinvoiceCloud.Billing.CreditNote
  alias RealinvoiceCloud.Billing.Customer
  alias RealinvoiceCloud.Billing.Invoice
  alias RealinvoiceCloud.Billing.InvoiceLine
  alias RealinvoiceCloud.Billing.Item
  alias RealinvoiceCloud.Repo

  @topic "billing:invoices"

  @doc """
  Subscribes the calling process to invoice activity.

  Messages arrive as `{:invoice_created, %Invoice{}}` or
  `{:credit_note_created, %CreditNote{}}`.
  """
  def subscribe do
    PubSub.subscribe(RealinvoiceCloud.PubSub, @topic)
  end

  defp broadcast(message) do
    PubSub.broadcast(RealinvoiceCloud.PubSub, @topic, message)
  end

  ## Invoices

  @doc """
  Lists invoices, newest first, with their customer preloaded.

  Accepts the same filters the list page exposes:

    * `:from`, `:to` — inclusive invoice date bounds (`Date` or ISO string)
    * `:node` — a `store_node_id`
    * `:q` — free text matched against invoice number or customer name

  Blank values are ignored, so a filter form can pass its params straight in.
  """
  def list_invoices(filters \\ %{}) do
    Invoice
    |> with_credit_totals()
    |> filter_invoices(filters)
    |> order_by([i], desc: i.date, desc: i.id)
    |> preload(:customer)
    |> Repo.all()
  end

  # One left join to a grouped subquery, so a list of invoices knows what has
  # been credited against each without a query per row.
  defp with_credit_totals(query) do
    credits =
      from c in CreditNote,
        group_by: c.original_invoice_id,
        select: %{
          original_invoice_id: c.original_invoice_id,
          count: count(c.id),
          total: sum(c.grand_total)
        }

    from i in query,
      left_join: c in subquery(credits),
      on: c.original_invoice_id == i.id,
      as: :credits,
      select_merge: %{
        credit_note_count: coalesce(c.count, 0),
        credited_total: coalesce(c.total, 0)
      }
  end

  @doc """
  Fetches one invoice with its customer, lines and each line's item preloaded.

  Raises `Ecto.NoResultsError` if there is no such invoice.
  """
  def get_invoice!(id) do
    credit_notes =
      from c in CreditNote,
        order_by: [desc: c.date, desc: c.id],
        preload: [lines: ^from(l in RealinvoiceCloud.Billing.CreditNoteLine, preload: :item)]

    Invoice
    |> with_credit_totals()
    |> preload([
      :customer,
      lines: ^from(l in InvoiceLine, preload: :item),
      credit_notes: ^credit_notes
    ])
    |> Repo.get!(id)
  end

  @doc """
  What an invoice is worth once the credit notes against it are taken off.
  """
  def net_total(%Invoice{} = invoice) do
    Decimal.sub(invoice.grand_total, to_decimal(invoice.credited_total))
  end

  @doc """
  How much has been credited against this invoice, as a decimal.
  """
  def credited_total(%Invoice{} = invoice), do: to_decimal(invoice.credited_total)

  @doc """
  Whether anything has been credited against this invoice.
  """
  def credited?(%Invoice{credit_note_count: count}) when is_integer(count), do: count > 0
  def credited?(%Invoice{}), do: false

  @doc """
  Inserts an invoice and its lines, then announces it on the invoice topic.

  This is the function the ingest API will call once it exists, which is why the
  broadcast lives here rather than in a controller.
  """
  def create_invoice(attrs) do
    %Invoice{}
    |> Invoice.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, invoice} ->
        invoice = get_invoice!(invoice.id)
        broadcast({:invoice_created, invoice})
        {:ok, invoice}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Reports whether an invoice would appear in a list built with these filters.

  The invoice list uses this to decide whether a broadcast invoice belongs in
  the rows currently on screen, so a filtered view does not suddenly show a row
  that does not match it.
  """
  def matches_filters?(%Invoice{} = invoice, filters) do
    Invoice
    |> with_credit_totals()
    |> where([i], i.id == ^invoice.id)
    |> filter_invoices(filters)
    |> Repo.exists?()
  end

  defp filter_invoices(query, filters) do
    Enum.reduce(filters, query, fn
      {_key, value}, query when value in [nil, ""] ->
        query

      {key, value}, query when key in [:from, "from"] ->
        case to_date(value) do
          {:ok, date} -> where(query, [i], i.date >= ^date)
          :error -> query
        end

      {key, value}, query when key in [:to, "to"] ->
        case to_date(value) do
          {:ok, date} -> where(query, [i], i.date <= ^date)
          :error -> query
        end

      {key, value}, query when key in [:node, "node"] ->
        where(query, [i], i.store_node_id == ^value)

      {key, "credited"}, query when key in [:credited, "credited"] ->
        where(query, [credits: c], not is_nil(c.original_invoice_id))

      {key, "uncredited"}, query when key in [:credited, "credited"] ->
        where(query, [credits: c], is_nil(c.original_invoice_id))

      {key, value}, query when key in [:q, "q"] ->
        pattern = "%#{escape_like(value)}%"

        query
        |> join(:left, [i], c in assoc(i, :customer), as: :search_customer)
        |> where(
          [i, search_customer: c],
          ilike(i.invoice_no, ^pattern) or ilike(c.name, ^pattern)
        )

      _other, query ->
        query
    end)
  end

  ## Credit notes

  @doc """
  Fetches one credit note with its invoice, lines and each line's item.
  """
  def get_credit_note!(id) do
    CreditNote
    |> preload([
      :original_invoice,
      lines: ^from(l in RealinvoiceCloud.Billing.CreditNoteLine, preload: :item)
    ])
    |> Repo.get!(id)
  end

  @doc """
  Inserts a credit note and its lines, then announces it.

  Broadcast because a credit note changes what an invoice is worth and what the
  day's revenue is, so any screen showing either has to hear about it.
  """
  def create_credit_note(attrs) do
    %CreditNote{}
    |> CreditNote.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, credit_note} ->
        credit_note = get_credit_note!(credit_note.id)
        broadcast({:credit_note_created, credit_note})
        {:ok, credit_note}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  The credit notes raised against an invoice, newest first.
  """
  def list_credit_notes_for_invoice(invoice_id) do
    CreditNote
    |> where([c], c.original_invoice_id == ^invoice_id)
    |> order_by([c], desc: c.date, desc: c.id)
    |> preload(lines: ^from(l in RealinvoiceCloud.Billing.CreditNoteLine, preload: :item))
    |> Repo.all()
  end

  ## Customers

  @doc """
  Lists customers by name.

  Accepts `:q` (matched against name, GSTIN or mobile) and `:node`.
  """
  def list_customers(filters \\ %{}) do
    Customer
    |> filter_customers(filters)
    |> order_by([c], asc: c.name)
    |> Repo.all()
  end

  defp filter_customers(query, filters) do
    Enum.reduce(filters, query, fn
      {_key, value}, query when value in [nil, ""] ->
        query

      {key, value}, query when key in [:node, "node"] ->
        where(query, [c], c.store_node_id == ^value)

      {key, value}, query when key in [:q, "q"] ->
        pattern = "%#{escape_like(value)}%"

        where(
          query,
          [c],
          ilike(c.name, ^pattern) or ilike(c.gstin, ^pattern) or ilike(c.mobile, ^pattern)
        )

      _other, query ->
        query
    end)
  end

  ## Items

  @doc """
  Lists catalogue items by code.

  Accepts `:q` (matched against code or description) and `:node`.
  """
  def list_items(filters \\ %{}) do
    Item
    |> filter_items(filters)
    |> order_by([i], asc: i.item_code)
    |> Repo.all()
  end

  defp filter_items(query, filters) do
    Enum.reduce(filters, query, fn
      {_key, value}, query when value in [nil, ""] ->
        query

      {key, value}, query when key in [:node, "node"] ->
        where(query, [i], i.store_node_id == ^value)

      {key, value}, query when key in [:q, "q"] ->
        pattern = "%#{escape_like(value)}%"
        where(query, [i], ilike(i.item_code, ^pattern) or ilike(i.description, ^pattern))

      _other, query ->
        query
    end)
  end

  ## Lookup and upsert by the desk's client id

  @doc """
  Finds a row previously ingested from this node under this client id, or `nil`.

  This is what makes ingest idempotent: a retried batch finds what it already
  wrote instead of writing it again.

  Scoped to the node on purpose. A client id is generated by a desk and is only
  unique within it — two desks can hand out the same id for unrelated rows, and
  looking one up globally would let one desk's retry resolve to another desk's
  record.
  """
  def get_by_client_id(type, node_id, client_id)

  def get_by_client_id(:customer, node_id, client_id),
    do: Repo.get_by(Customer, node_id: node_id, client_id: client_id)

  def get_by_client_id(:item, node_id, client_id),
    do: Repo.get_by(Item, node_id: node_id, client_id: client_id)

  def get_by_client_id(:invoice, node_id, client_id),
    do: Repo.get_by(Invoice, node_id: node_id, client_id: client_id)

  def get_by_client_id(:invoice_line, node_id, client_id),
    do: Repo.get_by(InvoiceLine, node_id: node_id, client_id: client_id)

  def get_by_client_id(:credit_note, node_id, client_id),
    do: Repo.get_by(CreditNote, node_id: node_id, client_id: client_id)

  def get_by_client_id(:credit_note_line, node_id, client_id),
    do:
      Repo.get_by(RealinvoiceCloud.Billing.CreditNoteLine,
        node_id: node_id,
        client_id: client_id
      )

  @doc """
  Inserts a customer, or updates the one already stored under this client id.

  Last write wins: a desk that edits a customer and re-syncs replaces what is
  here. That is the right default while the desk is the only place this data is
  editable.
  """
  def upsert_customer(nil, attrs), do: %Customer{} |> Customer.changeset(attrs) |> Repo.insert()

  def upsert_customer(%Customer{} = customer, attrs),
    do: customer |> Customer.changeset(attrs) |> Repo.update()

  @doc """
  Inserts a catalogue item, or updates the one already stored under this client id.
  """
  def upsert_item(nil, attrs), do: %Item{} |> Item.changeset(attrs) |> Repo.insert()

  def upsert_item(%Item{} = item, attrs), do: item |> Item.changeset(attrs) |> Repo.update()

  ## Billing desks

  @doc """
  Lists the distinct `store_node_id` values that have sent invoices.

  This is what populates the node filter — the back office learns which desks
  exist from the data they send, not from a configured list.
  """
  def list_store_nodes do
    Invoice
    |> select([i], i.store_node_id)
    |> distinct(true)
    |> order_by([i], asc: i.store_node_id)
    |> Repo.all()
  end

  ## Dashboard

  @doc """
  The headline numbers for the dashboard, as of `date` (defaults to today).

  Revenue is **net of credit notes**. Each figure carries its gross and credited
  parts too, so a screen can show what was billed and what was given back rather
  than only the difference.

  A credit note counts against its own date, not its original invoice's: it
  reduces the day it was issued, which is how the desk's books treat it and what
  keeps last month's reported takings from changing after the fact.
  """
  def dashboard_metrics(date \\ Date.utc_today()) do
    month_start = Date.beginning_of_month(date)

    %{
      date: date,
      today: totals_between(date, date),
      month: totals_between(month_start, date),
      by_node: revenue_by_node(date),
      last_invoice_at: last_invoice_date()
    }
  end

  defp totals_between(from, to) do
    gross =
      Invoice
      |> where([i], i.date >= ^from and i.date <= ^to)
      |> select([i], %{revenue: coalesce(sum(i.grand_total), 0), count: count(i.id)})
      |> Repo.one()

    credited =
      CreditNote
      |> where([c], c.date >= ^from and c.date <= ^to)
      |> select([c], %{credited: coalesce(sum(c.grand_total), 0), count: count(c.id)})
      |> Repo.one()

    gross_revenue = to_decimal(gross.revenue)
    credited_total = to_decimal(credited.credited)

    %{
      revenue: Decimal.sub(gross_revenue, credited_total),
      gross_revenue: gross_revenue,
      credited: credited_total,
      count: gross.count,
      credit_note_count: credited.count
    }
  end

  defp revenue_by_node(date) do
    gross =
      Invoice
      |> where([i], i.date == ^date)
      |> group_by([i], i.store_node_id)
      |> select([i], %{
        node: i.store_node_id,
        revenue: coalesce(sum(i.grand_total), 0),
        count: count(i.id)
      })
      |> Repo.all()
      |> Map.new(&{&1.node, &1})

    credited =
      CreditNote
      |> where([c], c.date == ^date)
      |> group_by([c], c.store_node_id)
      |> select([c], %{
        node: c.store_node_id,
        credited: coalesce(sum(c.grand_total), 0),
        count: count(c.id)
      })
      |> Repo.all()
      |> Map.new(&{&1.node, &1})

    # A desk that only issued credits today still belongs on the breakdown —
    # leaving it out would hide a refund-only day entirely.
    gross
    |> Map.keys()
    |> Enum.concat(Map.keys(credited))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn node ->
      billed = to_decimal(get_in(gross, [node, :revenue]))
      given_back = to_decimal(get_in(credited, [node, :credited]))

      %{
        node: node,
        revenue: Decimal.sub(billed, given_back),
        gross_revenue: billed,
        credited: given_back,
        count: get_in(gross, [node, :count]) || 0,
        credit_note_count: get_in(credited, [node, :count]) || 0
      }
    end)
  end

  defp last_invoice_date do
    Invoice
    |> select([i], max(i.date))
    |> Repo.one()
  end

  ## Bulk insert, used by the seeds

  @doc """
  Inserts a customer, raising on invalid data.
  """
  def create_customer!(attrs) do
    %Customer{} |> Customer.changeset(attrs) |> Repo.insert!()
  end

  @doc """
  Inserts a catalogue item, raising on invalid data.
  """
  def create_item!(attrs) do
    %Item{} |> Item.changeset(attrs) |> Repo.insert!()
  end

  @doc """
  Deletes every billing record, in foreign-key-safe order.

  Only used to rebuild the sample data (`RESEED=1 mix run priv/repo/seeds.exs`);
  it leaves staff accounts alone.
  """
  def delete_all_billing_data! do
    Multi.new()
    |> Multi.delete_all(:credit_note_lines, RealinvoiceCloud.Billing.CreditNoteLine)
    |> Multi.delete_all(:credit_notes, CreditNote)
    |> Multi.delete_all(:invoice_lines, InvoiceLine)
    |> Multi.delete_all(:invoices, Invoice)
    |> Multi.delete_all(:items, Item)
    |> Multi.delete_all(:customers, Customer)
    |> Repo.transaction()
  end

  @doc """
  Whether any invoice has been recorded yet.
  """
  def any_invoices? do
    Repo.exists?(Invoice)
  end

  # An empty SUM() comes back as a plain 0, and a virtual field is whatever the
  # query put there.
  defp to_decimal(nil), do: Decimal.new("0.00")
  defp to_decimal(%Decimal{} = value), do: value
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)

  defp to_date(%Date{} = date), do: {:ok, date}
  defp to_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp to_date(_value), do: :error

  # `%` and `_` are wildcards in LIKE, and `\` escapes them. A customer
  # searching for "100%" should not match every row.
  defp escape_like(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
