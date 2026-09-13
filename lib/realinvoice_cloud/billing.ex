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
  alias RealinvoiceCloud.Billing.Customer
  alias RealinvoiceCloud.Billing.Invoice
  alias RealinvoiceCloud.Billing.Item
  alias RealinvoiceCloud.Repo

  @topic "billing:invoices"

  @doc """
  Subscribes the calling process to invoice activity.

  Messages arrive as `{:invoice_created, %Invoice{}}`.
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
    |> filter_invoices(filters)
    |> order_by([i], desc: i.date, desc: i.id)
    |> preload(:customer)
    |> Repo.all()
  end

  @doc """
  Fetches one invoice with its customer, lines and each line's item preloaded.

  Raises `Ecto.NoResultsError` if there is no such invoice.
  """
  def get_invoice!(id) do
    Invoice
    |> preload([
      :customer,
      lines: ^from(l in RealinvoiceCloud.Billing.InvoiceLine, preload: :item)
    ])
    |> Repo.get!(id)
  end

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
  Finds a record previously ingested under this client id, or `nil`.

  This is what makes ingest idempotent: a retried batch finds what it already
  wrote instead of writing it again.
  """
  def get_by_client_id(:customer, client_id), do: Repo.get_by(Customer, client_id: client_id)
  def get_by_client_id(:item, client_id), do: Repo.get_by(Item, client_id: client_id)
  def get_by_client_id(:invoice, client_id), do: Repo.get_by(Invoice, client_id: client_id)

  def get_by_client_id(:invoice_line, client_id),
    do: Repo.get_by(RealinvoiceCloud.Billing.InvoiceLine, client_id: client_id)

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

  Returns revenue and invoice count for the day, the month to date, and a
  per-desk breakdown of the day's revenue, newest desks last.
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
    Invoice
    |> where([i], i.date >= ^from and i.date <= ^to)
    |> select([i], %{
      revenue: coalesce(sum(i.grand_total), 0),
      count: count(i.id)
    })
    |> Repo.one()
  end

  defp revenue_by_node(date) do
    Invoice
    |> where([i], i.date == ^date)
    |> group_by([i], i.store_node_id)
    |> order_by([i], asc: i.store_node_id)
    |> select([i], %{
      node: i.store_node_id,
      revenue: coalesce(sum(i.grand_total), 0),
      count: count(i.id)
    })
    |> Repo.all()
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
    |> Multi.delete_all(:invoice_lines, RealinvoiceCloud.Billing.InvoiceLine)
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
