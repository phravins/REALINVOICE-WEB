# RealInvoice Cloud — back office

The web back office for RealInvoice. Billing desks running the RealInvoice
desktop app sync their invoices, customers and items up here, where an
administrator can see the whole business in one place.

**Nothing syncs yet.** The data model, the reporting and the screens are built
and backed by sample data, but there is no ingest API: the desks have no way to
push anything up. That arrives once the desktop app has a sync worker and the
payload shape it sends is settled.

## Stack

| | |
|---|---|
| Framework | Phoenix 1.8 (LiveView) |
| Database | PostgreSQL |
| Components | [SaladUI](https://hexdocs.pm/salad_ui) on Tailwind CSS v4 |
| Auth | `mix phx.gen.auth` (email + password, magic-link sign-in) |

## Running it locally

You need Elixir 1.17+, Erlang/OTP 25+, and a Postgres you can reach.

```sh
mix setup                       # deps, database, seed admin, assets
mix phx.server                  # http://localhost:4000
```

`mix setup` seeds one owner account:

```
admin@realinvoice.local / realinvoice-dev-password
```

Sign in with it at `/users/log-in`. There is no sign-up page — see below.

> **No `mix.lock` yet.** This stage was built in an environment that could not
> reach `repo.hex.pm`, so the lockfile was never generated. The first
> `mix deps.get` on a machine with Hex access will create one — commit it.

### Database configuration

`config/dev.exs` and `config/test.exs` default to `postgres`/`postgres` on
`localhost:5432`. Override per machine with the standard Postgres environment
variables rather than editing the files:

```sh
PGUSER=me PGPASSWORD=secret PGHOST=db.local mix phx.server
```

Production reads `DATABASE_URL` and `SECRET_KEY_BASE` at runtime
(`config/runtime.exs`). No production credentials live in this repo.

## Data model

Four tables mirror the desktop app's core data model, all under the
`RealinvoiceCloud.Billing` context:

| | |
|---|---|
| `customers` | name, GSTIN, place of supply, mobile |
| `items` | code, description, rate, tax rate, UOM |
| `invoices` | number, date, customer, subtotal, CGST/SGST/IGST, grand total, payment type, `created_by` |
| `invoice_lines` | item, quantity, rate, tax rate, line total |

Every row carries a `store_node_id` — the billing desk it came from. Two things
follow from that, and both are enforced by the schema:

  * **Invoice numbers are unique per desk, not globally.** Each desk numbers its
    own invoices, so they all start again at `RI-2026-0001`. Item codes work the
    same way.
  * **A desk's figures are stored, never recomputed.** The desk is the authority
    on what it charged a customer. The changesets check integrity (present,
    non-negative, not both CGST/SGST and IGST at once) but do not reimplement the
    GST arithmetic. Cross-checking the desk's maths is a sensible thing to add
    when ingest exists; silently "correcting" it is not.

Money is `Decimal` everywhere, never a float, and is displayed with Indian digit
grouping (`₹12,34,567.50`) by `RealinvoiceCloudWeb.Format`.

`invoices.customer_id` is nullable: a counter sale with no customer record is
ordinary at a billing desk, and rejecting those on ingest would lose real
invoices. Such an invoice shows as "Counter sale".

`created_by` is a plain label. The cloud has no knowledge of a desk's local
cashier accounts, so it stores whatever the desk sends rather than resolving it
to a user.

### Live updates

`Billing.create_invoice/1` broadcasts on `"billing:invoices"`, and the invoice
list and dashboard subscribe. When ingest starts calling that function, new
invoices will appear in an open browser without a refresh. Nothing broadcasts in
production yet, so the path is covered by tests rather than in use.

## Sample data

`mix run priv/repo/seeds.exs` creates 3 customers, 6 items and 13 invoices
across two desks (`POS-01`, `POS-02`) and a spread of dates in the current
month. It is deterministic — the same figures on every machine — and idempotent.
To rebuild it from scratch:

```sh
RESEED=1 mix run priv/repo/seeds.exs
```

That discards and regenerates the billing data only; staff accounts are left
alone.

## Accounts

This is an internal admin tool, so **public registration is disabled** — there
is no `/users/register` route and no self-service sign-up. Accounts are
provisioned by an operator:

```sh
ADMIN_EMAIL=ops@osworks.in ADMIN_PASSWORD='…' mix run priv/repo/seeds.exs
```

The seed script is idempotent: re-running it leaves an existing account alone
rather than resetting its password.

Users carry a `role` of `owner` or `staff`. Only `owner` means anything today —
every account can reach every screen — but the column exists from the first
migration so splitting permissions later is a code change rather than a data
migration.

Back-office accounts are entirely separate from the cashier logins on each
billing desk; the two never share credentials.

Signed-in users can change their own email and password at `/users/settings`.
Forgotten passwords are handled by the "email me a link" option on the login
page, which signs you in so you can set a new one.

## Design

The palette is the OSWORKS house palette, shared conceptually with the Office
Console: a single rust accent (`#C1571F`) on warm cream and charcoal neutrals,
flat surfaces, hairline borders, small radii — no heavy boxed panels.

Every colour in the app is a design token, all of them defined in one block at
the top of `assets/css/app.css` for both light and dark. Re-skinning the app is
a change to that block and nothing else. Dark mode is a `.dark` class on
`<html>`, set before first paint by the inline script in `root.html.heex` and
toggled from the button in the top bar; the preference is remembered per
browser and defaults to the operating system setting.

## Layout of the code

```
lib/realinvoice_cloud/accounts/        auth context, user schema and tokens
lib/realinvoice_cloud/billing.ex       queries, filters, dashboard figures, PubSub
lib/realinvoice_cloud/billing/         customer, item, invoice, invoice_line
lib/realinvoice_cloud_web/components/
  layouts.ex                           app shell (sidebar + top bar) and auth shell
  core_components.ex                   only what SaladUI does not cover
  ../format.ex                         money, quantity and date formatting
lib/realinvoice_cloud_web/live/
  dashboard_live.ex                    today's revenue, counts, revenue by desk
  invoice_live/                        invoice list (filters, live updates) and detail
  customer_live/                       customer list
  item_live/                           catalogue list
  section_live.ex                      the Nodes placeholder
  settings_live.ex                     Settings → Account
  user_live/                           login, confirmation, email & password
priv/repo/seeds.exs                    owner account and sample billing data
```

## Common tasks

```sh
mix test          # full suite
mix precommit     # compile with warnings as errors, check deps, format, test
mix assets.build  # rebuild CSS and JS once
```
