# RealInvoice Cloud — back office

The web back office for RealInvoice. Billing desks running the RealInvoice
desktop app sync their invoices, customers and items up here, where an
administrator can see the whole business in one place.

Desks push their data to `POST /api/sync/ingest`, authenticated with a per-desk
API token issued from the back office; the screens update live as it arrives.

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
list and dashboard subscribe. Ingest calls that function, so a synced invoice
appears in an open browser without a refresh.

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

## Sync API

`POST /api/sync/ingest` is where a billing desk's sync worker pushes its data.

Every request must present the token of a desk registered under **Settings →
Nodes**. The token is hashed on the way in and looked up against active nodes
only; anything that does not resolve to one is a `401`. There is no fallback and
no way to sync without a token.

What is still deferred: **multi-tenancy**. Every registered node belongs to the
one account this server holds. The `nodes.tenant_id` column exists and is
indexed, but nothing populates or filters on it, so a token is scoped to a desk
and not yet to a tenant.

### Request

```
POST /api/sync/ingest
Authorization: Bearer <the desk's token>      (or: X-Api-Token: <token>)
Content-Type: application/json
```

```json
{
  "rows": [
    { "client_id": "c-9f2a", "type": "customer",
      "data": { "name": "Vaanavil Systems Pvt Ltd", "gstin": "33AABCV1234M1Z7",
                "place_of_supply": "Tamil Nadu", "mobile": "+91 98400 11223" } },

    { "client_id": "i-41b7", "type": "item",
      "data": { "item_code": "RK-42U-PRO", "description": "42U Server Rack Pro",
                "rate": "48500.00", "tax_rate": "18.00", "uom": "Nos" } },

    { "client_id": "v-77c1", "type": "invoice",
      "data": { "invoice_no": "RI-2026-0001", "date": "2026-09-13",
                "customer_client_id": "c-9f2a",
                "subtotal": "48500.00", "cgst": "4365.00", "sgst": "4365.00",
                "igst": "0.00", "grand_total": "57230.00",
                "payment_type": "UPI", "created_by": "Anitha R (till-1)",
                "lines": [ { "client_id": "l-1", "item_client_id": "i-41b7",
                             "qty": "1", "rate": "48500.00", "tax_rate": "18.00",
                             "line_total": "48500.00" } ] } }
  ]
}
```

  * `client_id` is the desk's own identifier for the row — any string, stable
    forever, never reused. **This is what makes ingest idempotent**: a retried
    batch finds what it already wrote instead of inserting it again.
  * `type` is one of `customer`, `item`, `invoice`, `invoice_line`.
  * Invoices name their customer with `customer_client_id`, and lines name their
    item with `item_client_id` — the desk's identifiers, which the server
    translates to its own primary keys. A desk never sends this server's ids.
  * Lines may be **nested** in the invoice's `lines` (above) or sent as their own
    `invoice_line` rows carrying `"invoice_client_id": "v-77c1"`. Both work; send
    whichever suits the worker.
  * Rows may arrive in any order — the server processes customers and items
    first, then invoices, then standalone lines.
  * **The desk is whichever node's token authenticated the request.** There is no
    `store_node_id` in the payload — it comes from the node's name. A desk cannot
    claim to be another desk, and a `store_node_id` sent anyway is ignored (and
    logged, since it means a misconfiguration).
  * Money and quantities are strings, to survive the trip without a float
    rounding them.

### Response

Always `200` with a result per row, in the order sent — a batch is never all-or-
nothing, so the worker can tell exactly which rows to retry or report:

```json
{
  "batch": { "store_node_id": "POS-01", "received": 3, "accepted": 2, "rejected": 1 },
  "results": [
    { "client_id": "c-9f2a", "type": "customer", "status": "accepted",
      "action": "inserted", "id": 12 },
    { "client_id": "v-77c1", "type": "invoice", "status": "accepted",
      "action": "unchanged", "id": 7 },
    { "client_id": "i-41b7", "type": "item", "status": "rejected",
      "errors": { "rate": ["must be greater than or equal to 0"] } }
  ]
}
```

`action` is `inserted`, `updated` or `unchanged`. `unchanged` means the row was
already here — a successful retry, not a failure.

Other statuses: `401` when the token is missing, unknown, or belongs to a revoked
node — one identical response for all three, so the endpoint cannot be used to
probe which tokens exist. `422` when the batch itself cannot be read (`rows` not
a list, more than 1000 rows).

### Rules

  * **Idempotent, per desk.** Re-sending a batch changes nothing and reports the
    same ids. A row's identity is (node, `client_id`) — client ids are generated
    by a desk and are only unique within it, so two desks may use the same id for
    unrelated rows without colliding.
  * **Invoices are append-only.** Once stored, an invoice is never rewritten,
    whatever a later batch says — a re-sent invoice comes back `unchanged`.
    Customers and items are upserted, last write wins.
  * **A row fails on its own.** Each unit is its own transaction, so one invalid
    row does not roll back the rest of the batch. An invoice and its lines are a
    single unit: all of it lands or none of it does.

### Trying it

Register a desk under **Settings → Nodes**, copy the token it shows you, then:

```sh
curl -X POST http://localhost:4000/api/sync/ingest \
  -H 'Authorization: Bearer rin_the-token-you-copied' \
  -H 'Content-Type: application/json' \
  -d @batch.json
```

An accepted invoice appears in the Invoices list and moves the Dashboard totals
in any open browser immediately, with no refresh — `Billing.create_invoice/1`
broadcasts on `"billing:invoices"` and both LiveViews subscribe.

## Billing desks (nodes)

A node is a billing desk allowed to sync. Owners register them under **Settings →
Nodes**; staff accounts cannot see the page and the nav entry is hidden from them.

Registering a node issues a token and **shows it exactly once**. The server keeps
only its SHA-256, so there is no "show it again" — if the token is lost, register
the desk again. Revoking a node flips its status and its token stops working on
its very next request; the record and its history stay, and it can be reinstated
with the same token.

The list shows each desk's status and `last_seen_at`, which is updated on every
successful ingest request — that is the signal a per-desk health display is built
on.

### Why SHA-256 rather than bcrypt

Passwords get bcrypt because they are low-entropy and guessable, and the cost is
the defence. A node token is 32 bytes straight from the CSPRNG, so there is
nothing to guess. More practically, bcrypt salts every hash, so a bcrypt hash
cannot be looked up — authenticating a request would mean running bcrypt against
every active node in turn. SHA-256 makes it one indexed row read, which is what
this application's own `Accounts.UserToken` already does for session and
magic-link tokens.

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
lib/realinvoice_cloud/sync.ex          batch ingest: idempotency, per-row results
lib/realinvoice_cloud/nodes.ex         registering desks, authenticating tokens
lib/realinvoice_cloud/nodes/           the node schema
lib/realinvoice_cloud_web/components/
  layouts.ex                           app shell (sidebar + top bar) and auth shell
  core_components.ex                   only what SaladUI does not cover
  ../format.ex                         money, quantity and date formatting
lib/realinvoice_cloud_web/controllers/
  sync_ingest_controller.ex            POST /api/sync/ingest
lib/realinvoice_cloud_web/plugs/
  require_sync_token.ex                resolves a token to an active node
lib/realinvoice_cloud_web/live/
  dashboard_live.ex                    today's revenue, counts, revenue by desk
  invoice_live/                        invoice list (filters, live updates) and detail
  customer_live/                       customer list
  item_live/                           catalogue list
  node_live/                           registering and revoking billing desks
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
