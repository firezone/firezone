# Firezone Elixir Development

Before reading this doc, make sure you've read through our [CONTRIBUTING](../docs/CONTRIBUTING.md) guide.

## Getting Started

This is not an in depth guide for setting up all dependencies, but it should give you a starting point.

Prerequisites:

- All prerequisites in the [CONTRIBUTING](../docs/CONTRIBUTING.md) guide
- From the `elixir/` directory, install all tools from `.tool-versions` using
  [Mise](https://mise.jdx.dev/) (`cd elixir && mise install`) or
  [asdf](https://asdf-vm.com/) (`cd elixir && asdf install`)

From the top level directory of the Firezone repo start the Postgres container:

```
docker compose up -d postgres
```

Inside the `/elixir` directory run the following commands:

```
# Install dependencies
# --------------------
> mix deps.get

# Generate dev cert, install npm packages and build assets
# ---------------------------------------------------------
> mix phx.gen.cert
> mix setup

# Setup and seed the DB
# ---------------------
> mix ecto.seed

# Start the portal:
# ------------------
> iex -S mix
```

The web and API endpoints should now be running:

- Web -> https://localhost:13443/
- API -> wss://localhost:13001/

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

### MCP server for local development

MCP is disabled unless the global `features` row for `mcp` is enabled. Local
seeds enable that flag. All tools use this single rollout flag; OAuth scopes
and actor permissions control which actions a caller can perform. Tool
annotations are descriptive hints, not authorization or confirmation controls.

MCP request logs retain `/mcp` as the request path. The `mcp` metadata records
the requested tool, dispatched REST method/path, and outcome/status without
arguments or returned secrets. `dispatched` without a terminal outcome means
execution may have occurred but its result is unknown; do not automatically
retry a destructive operation based on that record.

- Start the portal as described above.

- Add the server:

  ```
  claude mcp add --transport http firezone https://localhost:13001/mcp
  ```

  In the Claude app, add a custom connector pointing at the same URL instead.
  Either way it runs on the same machine, so no tunnel is needed.

- Get past the dev certificate. Claude Code is compiled with Bun, which neither
  reads the system trust store nor honours `NODE_EXTRA_CA_CERTS` for the
  requests it makes to an MCP server. A certificate that `curl` and the browser
  already accept still fails, with `unable to verify the first certificate`.

  Until Claude Code supports a custom CA, the way through is to turn
  verification off for that one process:

  ```
  NODE_TLS_REJECT_UNAUTHORIZED=0 claude
  ```

  That disables certificate verification for everything the process does, so
  use it only for local development against localhost, and keep it out of your
  shell rc.

- Check it worked before going further:

  ```
  NODE_TLS_REJECT_UNAUTHORIZED=0 claude mcp get firezone
  ```

  `Needs authentication` means TLS is out of the way and the OAuth flow is
  next. `Failed to connect` means it is not.

- Run `/mcp` in Claude Code to start the OAuth flow, or open the connector in
  the app.

- Claude opens a browser to approve the connection. Sign in with a seeded
  account; `mix ecto.seed` sets every actor's password to `Firezone1234`.

- The consent screen lists the permissions Claude asked for. Approving mints an
  access token, and Claude's tool list is then whatever those scopes allow.

The server advertises no scopes, so a client with none configured asks for none
and the consent screen offers every supported scope, with the read-only preset
initially selected. The person can narrow or broaden that selection. A client
can instead ask for a specific set, which becomes a hard ceiling on what the
screen may grant. In Claude Code:

```
claude mcp add-json firezone \
  '{"type":"http","url":"https://localhost:13001/mcp","oauth":{"scopes":"policies:read policies:write"}}'
```

To disconnect afterwards, open **Your settings** from the account menu and use
the Disconnect button under Connected apps. That revokes the token immediately.

#### How the clients identify themselves

This authorization server identifies clients by a metadata document they host
themselves, advertised as `client_id_metadata_document_supported` in
`/.well-known/oauth-authorization-server`. It does not implement RFC 7591
dynamic client registration, and there is no `registration_endpoint`.

Both supported clients cope with that:

- Claude Code supports Client ID Metadata Documents and discovers them
  automatically when dynamic registration is unavailable.
- ChatGPT recommends CIMD with public-client token exchange (`none`), which is
  the only method this server advertises.

So neither needs anything hosted or registered on your side.

#### Connecting something other than Claude

Any client works provided it identifies itself the same way. Its `client_id`
must be an `https` URL with a non-empty path, serving a document that names
itself:

```json
{
  "client_id": "https://example.com/mcp-client.json",
  "client_name": "My Local MCP Client",
  "redirect_uris": ["http://127.0.0.1:33418/callback"]
}
```

Redirect URIs are matched exactly, with no prefix or wildcard matching.

That document is fetched with mandatory SSRF protection, which refuses private
and reserved addresses, so the document cannot be served from `localhost`.
This protection is attached specifically to OAuth client metadata and remains
active even when `HTTP_CLIENT_SSRF_PROTECTION_ENABLED=false` disables the
deployment-wide HTTP-client protection for other integrations.

Two request parameters are easy to miss:

- `scope` may be omitted. The consent screen then lets the person choose from
  every supported scope and initially selects the read-only preset. When it is
  present, it is a hard ceiling on what the consent screen may grant. Draw
  values from `scopes_supported` in the authorization-server metadata.
- `resource` must be `https://localhost:13001/mcp`. Tokens are minted for that
  exact audience and refused anywhere else.

A client running off the machine needs `api_external_url` and `web_external_url`
pointed at a reachable hostname, such as a tunnel, since the metadata documents
and the token audience are all derived from them.
