defmodule RealinvoiceCloudWeb.InvoiceLive.Show do
  @moduledoc """
  One invoice: who it was for, what was on it, and what it came to.

  Read-only, like everything else in the back office at this stage — the desk
  that issued the invoice is the authority on its contents.
  """
  use RealinvoiceCloudWeb, :live_view

  alias RealinvoiceCloud.Billing

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    invoice = Billing.get_invoice!(id)

    {:ok,
     socket
     |> assign(:invoice, invoice)
     |> assign(:page_title, invoice.invoice_no)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active={:invoices}
      title={@invoice.invoice_no}
      subtitle={"#{date(@invoice.date)} · #{@invoice.store_node_id}"}
    >
      <:actions>
        <.link navigate={~p"/invoices"}>
          <.button variant="ghost" size="sm">
            <.icon name="hero-arrow-left" class="mr-1.5 size-4" /> All invoices
          </.button>
        </.link>
      </:actions>

      <div class="max-w-4xl space-y-12">
        <section>
          <.section_heading title="Invoice" />
          <.detail_list>
            <:row label="Invoice number">{@invoice.invoice_no}</:row>
            <:row label="Date">{date(@invoice.date)}</:row>
            <:row label="Billing desk">
              <.badge variant="secondary">{@invoice.store_node_id}</.badge>
            </:row>
            <:row label="Payment type">{@invoice.payment_type}</:row>
            <:row label="Billed by">{@invoice.created_by || "—"}</:row>
          </.detail_list>
        </section>

        <section>
          <.section_heading
            title="Customer"
            description={
              is_nil(@invoice.customer) &&
                "A counter sale — the desk recorded no customer against this invoice."
            }
          />
          <.detail_list :if={@invoice.customer}>
            <:row label="Name">{@invoice.customer.name}</:row>
            <:row label="GSTIN">{@invoice.customer.gstin || "—"}</:row>
            <:row label="Place of supply">{@invoice.customer.place_of_supply || "—"}</:row>
            <:row label="Mobile">{@invoice.customer.mobile || "—"}</:row>
          </.detail_list>
        </section>

        <section>
          <.section_heading title="Line items" />

          <div class="overflow-x-auto">
            <.table>
              <.table_header>
                <.table_row>
                  <.table_head>Item</.table_head>
                  <.table_head class="text-right">Qty</.table_head>
                  <.table_head class="text-right">Rate</.table_head>
                  <.table_head class="text-right">Tax</.table_head>
                  <.table_head class="text-right">Line total</.table_head>
                </.table_row>
              </.table_header>
              <.table_body>
                <.table_row :for={line <- @invoice.lines}>
                  <.table_cell>
                    <span class="font-medium">{line.item.description || line.item.item_code}</span>
                    <span class="block text-xs text-muted-foreground">
                      {line.item.item_code}{if line.item.uom, do: " · #{line.item.uom}"}
                    </span>
                  </.table_cell>
                  <.table_cell class="text-right whitespace-nowrap">{qty(line.qty)}</.table_cell>
                  <.table_cell class="text-right whitespace-nowrap">{money(line.rate)}</.table_cell>
                  <.table_cell class="text-right whitespace-nowrap">
                    {percent(line.tax_rate)}
                  </.table_cell>
                  <.table_cell class="text-right font-medium whitespace-nowrap">
                    {money(line.line_total)}
                  </.table_cell>
                </.table_row>
              </.table_body>
            </.table>
          </div>
        </section>

        <section>
          <.section_heading
            title="Summary"
            description="Figures as sent by the billing desk. The back office stores them, it does not recompute them."
          />

          <dl class="ml-auto max-w-sm divide-y divide-border border-y border-border">
            <div class="flex items-baseline justify-between gap-6 py-3">
              <dt class="text-sm text-muted-foreground">Taxable value</dt>
              <dd class="text-sm">{money(@invoice.subtotal)}</dd>
            </div>
            <div :if={positive?(@invoice.cgst)} class="flex items-baseline justify-between gap-6 py-3">
              <dt class="text-sm text-muted-foreground">CGST</dt>
              <dd class="text-sm">{money(@invoice.cgst)}</dd>
            </div>
            <div :if={positive?(@invoice.sgst)} class="flex items-baseline justify-between gap-6 py-3">
              <dt class="text-sm text-muted-foreground">SGST</dt>
              <dd class="text-sm">{money(@invoice.sgst)}</dd>
            </div>
            <div :if={positive?(@invoice.igst)} class="flex items-baseline justify-between gap-6 py-3">
              <dt class="text-sm text-muted-foreground">IGST</dt>
              <dd class="text-sm">{money(@invoice.igst)}</dd>
            </div>
            <div class="flex items-baseline justify-between gap-6 py-3">
              <dt class="text-sm font-medium">Grand total</dt>
              <dd class="text-base font-semibold">{money(@invoice.grand_total)}</dd>
            </div>
          </dl>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp positive?(nil), do: false
  defp positive?(%Decimal{} = amount), do: Decimal.gt?(amount, 0)
end
