# RealInvoice Cloud — back office

The web back office for RealInvoice. Billing desks running the RealInvoice
desktop app sync their invoices, customers and items up here, where an
administrator can see the whole business in one place.

**Stage 1 (this repo's current state) is the shell only.** Staff can sign in and
move around the app, but nothing syncs yet: there is no ingest API and no Ecto
schemas for invoices, customers or items. Those arrive once the desktop app has
a sync worker and the payload shape it sends is settled.

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

### Database configuration

`config/dev.exs` and `config/test.exs` default to `postgres`/`postgres` on
`localhost:5432`. Override per machine with the standard Postgres environment
variables rather than editing the files:

```sh
PGUSER=me PGPASSWORD=secret PGHOST=db.local mix phx.server
```

Production reads `DATABASE_URL` and `SECRET_KEY_BASE` at runtime
(`config/runtime.exs`). No production credentials live in this repo.

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
lib/realinvoice_cloud_web/components/
  layouts.ex                           app shell (sidebar + top bar) and auth shell
  core_components.ex                   only what SaladUI does not cover
lib/realinvoice_cloud_web/live/
  dashboard_live.ex                    landing page, empty until desks sync
  section_live.ex                      Invoices/Customers/Items/Nodes placeholders
  settings_live.ex                     Settings → Account
  user_live/                           login, confirmation, email & password
priv/repo/seeds.exs                    provisions the owner account
```

## Common tasks

```sh
mix test          # full suite
mix precommit     # compile with warnings as errors, check deps, format, test
mix assets.build  # rebuild CSS and JS once
```
