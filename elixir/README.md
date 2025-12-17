# Firezone Elixir Development

Before reading this doc, make sure you've read through our [CONTRIBUTING](../docs/CONTRIBUTING.md) guide.

## Getting Started

This is not an in depth guide for setting up all dependencies, but it should give you a starting point.

Prerequisites:

- All prerequisites in the [CONTRIBUTING](../docs/CONTRIBUTING.md) guide
- Install ASDF and all plugins/tools from `.tool-version` in the top level of the Firezone repo
- Install [pnpm](https://pnpm.io/)

From the top level director of the Firezone repo start the Postgres container:

```
docker compose up -d postgres
```

Inside the `/elixir` directory run the following commands:

```
# Install dependencies
# --------------------
> mix deps.get

# Generate dev cert, install npm packages and build assets
# -------------------------------------
> cd apps/web/
> mix phx.gen.cert
> mix setup

# Setup and seed the DB
# ---------------------
> cd ../..
> mix ecto.seed

# Start all of the portal Elixir apps:
# ------------------------------------
> iex -S mix
```

The web and api applications should now be running:

- Web -> https://localhost:13443/
- API -> ws://localhost:13001/

### Stripe integration for local development

Prerequisites:

- Stripe account
- Stripe CLI

Steps:

- Reset and seed the database (seeds use static IDs that correspond to staging setup on Stripe):

  ```
  mix do ecto.reset, ecto.seed
  ```

- Start Stripe CLI webhook proxy:

  ```
  stripe listen --forward-to localhost:13001/integrations/stripe/webhooks
  ```

- Start the Phoenix server with enabled billing from the elixir/ folder using a test mode token:
  ```
  cd elixir/
  BILLING_ENABLED=true STRIPE_SECRET_KEY="...copy from stripe dashboard..." STRIPE_WEBHOOK_SIGNING_SECRET="...copy from stripe cli tool.." mix phx.server
  ```

When updating the billing plan in stripe, use the Stripe Testing Docs for how to add test payment info

### WorkOS integration for local development

Prerequisites:

- WorkOS account

WorkOS is currently being used for JumpCloud directory sync integration. This allows JumpCloud users to use SCIM on the JumpCloud side, rather than having to give Firezone an admin JumpCloud API token.

#### Connecting WorkOS in dev mode for manual testing

If you are not planning to use the JumpCloud provider in your local development setup, then no additional setup is needed.
However, if you need to use the JumpCloud provider locally, you will need to obtain an API Key and Client ID from the [WorkOS Dashboard](https://dashboard.workos.com/api-keys).

After obtaining WorkOS API credentials, you will need to make sure they are set in the environment ENVs when starting your local dev instance of Firezone. As an example:

```
WORKOS_API_KEY="..." WORKOS_CLIENT_ID="..." mix phx.server
```

### Acceptance tests

You can disable headless mode for the browser by adding

```
@tag debug: true
feature ....
```
