# Welcome to Elixir-land!

This README provides an overview for running and managing Firezone's
Elixir-based control plane.

## Running Control Plane for local development

You can use the [Top-Level Docker Compose](../docker-compose.yml) to start any
services locally. The `web` and `api` compose services are built application
releases that are pretty much the same as the ones we run in production, while
the `elixir` compose service runs raw Elixir code, without a built release.

This means you'll want to use the `elixir` compose service to run Mix tasks and
any Elixir code on-the-fly, but you can't do that in `web`/`api` so easily
because Elixir strips out Mix and other tooling
[when building an application release](https://hexdocs.pm/mix/Mix.Tasks.Release.html).

`elixir` additionally caches `_build` and `node_modules` to speed up compilation
time and syncs `/apps`, `/config` and other folders with the host machine.

```bash
# Make sure to run this every time code in elixir/ changes,
# docker doesn't do that for you!
❯ docker-compose build

# Create the database
#
# Hint: you can run any mix commands like this,
# eg. mix ecto.reset will reset your database
#
# Also to drop the database you need to stop all active connections,
# so if you get an error stop all services first:
#
#   docker-compose down
#
# Or you can just run both reset and seed in one-liner:
#
#   docker-compose run elixir /bin/sh -c "cd apps/domain && mix do ecto.reset, ecto.seed"
#
❯ docker-compose run elixir /bin/sh -c "cd apps/domain && mix ecto.create"

# Ensure database is migrated before running seeds
❯ docker-compose run api bin/migrate
# or
❯ docker-compose run elixir /bin/sh -c "cd apps/domain && mix ecto.migrate"

# Seed the database
# Hint: some access tokens will be generated and written to stdout,
# don't forget to save them for later
❯ docker-compose run api bin/seed
# or
❯ docker-compose run elixir /bin/sh -c "cd apps/domain && mix ecto.seed"

# Start the API service for control plane sockets while listening to STDIN
# (where you will see all the logs)
❯ docker-compose up api --build
```

Now you can verify that it's working by connecting to a websocket:

<details>
  <summary>Gateway</summary>

```bash
# Note: The token value below is an example. The token value you will need is generated and printed out when seeding the database, as described earlier in the document.
❯ export GATEWAY_TOKEN_FROM_SEEDS=".SFMyNTY.g2gDaANtAAAAJGM4OWJjYzhjLTkzOTItNGRhZS1hNDBkLTg4OGFlZjZkMjhlMG0AAAAkMjI3NDU2MGItZTk3Yi00NWU0LThiMzQtNjc5Yzc2MTdlOThkbQAAADhPMDJMN1VTMkozVklOT01QUjlKNklMODhRSVFQNlVPOEFRVk82VTVJUEwwVkpDMjJKR0gwPT09PW4GAF3gLBONAWIAAVGA.DCT0Qv80qzF5OQ6CccLKXPLgzC3Rzx5DqzDAh9mWAww"

❯ websocat --header="User-Agent: iOS/12.7 (iPhone) connlib/0.7.412" "ws://127.0.0.1:13000/gateway/websocket?token=${GATEWAY_TOKEN_FROM_SEEDS}&external_id=thisisrandomandpersistent&name=kkX1&public_key=kceI60D6PrwOIiGoVz6hD7VYCgD1H57IVQlPJTTieUE="

# After this you need to join the `gateway` topic.
# For details on this structure see https://hexdocs.pm/phoenix/Phoenix.Socket.Message.html
❯ {"event":"phx_join","topic":"gateway","payload":{},"ref":"unique_string_ref","join_ref":"unique_join_ref"}

{"ref":"unique_string_ref","payload":{"status":"ok","response":{}},"topic":"gateway","event":"phx_reply"}
{"ref":null,"payload":{"interface":{"ipv6":"fd00:2021:1111::35:f630","ipv4":"100.77.125.87"},"ipv4_masquerade_enabled":true,"ipv6_masquerade_enabled":true},"topic":"gateway","event":"init"}
```

</details>
<details>
  <summary>Relay</summary>

```bash
# Note: The token value below is an example. The token value you will need is generated and printed out when seeding the database, as described earlier in the document.
❯ export RELAY_TOKEN_FROM_SEEDS=".SFMyNTY.g2gDaANtAAAAJGM4OWJjYzhjLTkzOTItNGRhZS1hNDBkLTg4OGFlZjZkMjhlMG0AAAAkNTQ5YzQxMDctMTQ5Mi00ZjhmLWE0ZWMtYTlkMmE2NmQ4YWE5bQAAADhQVTVBSVRFMU84VkRWTk1ITU9BQzc3RElLTU9HVERJQTY3MlM2RzFBQjAyT1MzNEg1TUUwPT09PW4GAJeo1TONAWIAAVGA.Vi3gCkFKoWH03uSUshAYYzRhw7eKQxYw1piFnkFPGtA"

❯ websocat --header="User-Agent: Linux/5.2.6 (Debian; x86_64) relay/0.7.412" "ws://127.0.0.1:8081/relay/websocket?token=${RELAY_TOKEN_FROM_SEEDS}&ipv4=24.12.79.100&ipv6=4d36:aa7f:473c:4c61:6b9e:2416:9917:55cc"

# Here is what you will see in docker logs firezone-api-1
# {"time":"2023-06-05T23:16:01.537Z","severity":"info","message":"CONNECTED TO API.Relay.Socket in 251ms\n  Transport: :websocket\n  Serializer: Phoenix.Socket.V1.JSONSerializer\n  Parameters: %{\"ipv4\" => \"24.12.79.100\", \"ipv6\" => \"4d36:aa7f:473c:4c61:6b9e:2416:9917:55cc\", \"stamp_secret\" => \"[FILTERED]\", \"token\" => \"[FILTERED]\"}","metadata":{"domain":["elixir"],"erl_level":"info"}}

# After this you need to join the `relay` topic and pass a `stamp_secret` in the payload.
# For details on this structure see https://hexdocs.pm/phoenix/Phoenix.Socket.Message.html
❯ {"event":"phx_join","topic":"relay","payload":{"stamp_secret":"makemerandomplz"},"ref":"unique_string_ref","join_ref":"unique_join_ref"}

{"event":"phx_reply","payload":{"response":{},"status":"ok"},"ref":"unique_string_ref","topic":"relay"}
{"event":"init","payload":{},"ref":null,"topic":"relay"}
```

</details>
<details>
  <summary>Client</summary>

```bash
# Note: The token value below is an example. The token value you will need is generated and printed out when seeding the database, as described earlier in the document.
❯ export CLIENT_TOKEN_FROM_SEEDS="n.SFMyNTY.g2gDaANtAAAAJGM4OWJjYzhjLTkzOTItNGRhZS1hNDBkLTg4OGFlZjZkMjhlMG0AAAAkN2RhN2QxY2QtMTExYy00NGE3LWI1YWMtNDAyN2I5ZDIzMGU1bQAAACtBaUl5XzZwQmstV0xlUkFQenprQ0ZYTnFJWktXQnMyRGR3XzJ2Z0lRdkZnbgYAGUmu74wBYgABUYA.UN3vSLLcAMkHeEh5VHumPOutkuue8JA6wlxM9JxJEPE"

# Panel will only accept token if it's coming with this User-Agent header and from IP 172.28.0.1
❯ export CLIENT_USER_AGENT="iOS/12.5 (iPhone) connlib/0.7.412"

❯ websocat --header="User-Agent: ${CLIENT_USER_AGENT}" "ws://127.0.0.1:8081/client/websocket?token=${CLIENT_TOKEN_FROM_SEEDS}&external_id=thisisrandomandpersistent&name=kkX1&public_key=kceI60D6PrwOIiGoVz6hD7VYCgD1H57IVQlPJTTieUE="

# Here is what you will see in docker logs firezone-api-1
# firezone-api-1  | {"domain":["elixir"],"erl_level":"info","logging.googleapis.com/sourceLocation":{"file":"lib/phoenix/logger.ex","line":306,"function":"Elixir.Phoenix.Logger.phoenix_socket_connected/4"},"message":"CONNECTED TO API.Client.Socket in 83ms\n  Transport: :websocket\n  Serializer: Phoenix.Socket.V1.JSONSerializer\n  Parameters: %{\"external_id\" => \"thisisrandomandpersistent\", \"name\" => \"kkX1\", \"public_key\" => \"[FILTERED]\", \"token\" => \"[FILTERED]\"}","severity":"INFO","time":"2023-06-23T21:01:49.566Z"}

# After this you need to join the `client` topic and pass a `stamp_secret` in the payload.
# For details on this structure see https://hexdocs.pm/phoenix/Phoenix.Socket.Message.html
❯ {"event":"phx_join","topic":"client","payload":{},"ref":"unique_string_ref","join_ref":"unique_join_ref"}

{"ref":"unique_string_ref","topic":"client","event":"phx_reply","payload":{"status":"ok","response":{}}}
{"ref":null,"topic":"client","event":"init","payload":{"interface":{"ipv6":"fd00:2021:1111::11:f4bd","upstream_dns":[],"ipv4":"100.71.71.245"},"resources":[{"id":"4429d3aa-53ea-4c03-9435-4dee2899672b","name":"172.20.0.1/16","type":"cidr","address":"172.20.0.0/16"},{"id":"85a1cffc-70d3-46dd-aa6b-776192af7b06","name":"gitlab.mycorp.com","type":"dns","address":"gitlab.mycorp.com","ipv6":"fd00:2021:1111::5:b370","ipv4":"100.85.109.146"}]}}

# List online relays for a Resource
❯ {"event":"prepare_connection","topic":"client","payload":{"resource_id":"1f27735f-651d-49e8-840c-8f1ba581d88e"},"ref":"unique_prepare_connection_ref"}

{"ref":"unique_prepare_connection_ref","payload":{"status":"ok","response":{"relays":[{"type":"turn","uri":"turn:189.172.72.111:3478","username":"1738022400:4ZxvSNDzU98MJiEjsR8DOA","password":"TVZvSgIGFK0TtNDXFVU9gv9a1WDz2Ou7RTEUis4E6To","expires_at":1738022400},{"type":"turn","uri":"turn:[::1]:3478","username":"1738022400:KCYrRTRmfGNAEEe7KyjHkA","password":"8KYplQOKBf5smJRZDhC54kiKKNVmUxsVxH1V8xfY/do","expires_at":1738022400}],"resource_id":"1f27735f-651d-49e8-840c-8f1ba581d88e","gateway_remote_ip":"127.0.0.1","gateway_id":"6e52c0ce-ccd9-46d9-8715-796ec9812719"}},"topic":"client","event":"phx_reply"}
{"event":"request_connection","topic":"client","payload":{"resource_id":"1f27735f-651d-49e8-840c-8f1ba581d88e","client_payload":"RTC_SD","client_preshared_key":"+HapiGI5UdeRjKuKTwk4ZPPYpCnlXHvvqebcIevL+2A="},"ref":"unique_request_connection_ref"}

# Initiate connection to a resource
❯ {"event":"request_connection","topic":"client","payload":{"gateway_id":"6e52c0ce-ccd9-46d9-8715-796ec9812719","resource_id":"1f27735f-651d-49e8-840c-8f1ba581d88e","client_payload":"RTC_SD","client_preshared_key":"+HapiGI5UdeRjKuKTwk4ZPPYpCnlXHvvqebcIevL+2A="},"ref":"unique_request_connection_ref"}

```

Note: when you run multiple commands it can hang because Phoenix expects a
heartbeat packet every 5 seconds, so it can kill your websocket if you send
commands slower than that.

</details>
<br />

You can reset the database (eg. when there is a migration that breaks data model
for unreleased versions) using following command:

```bash
❯ docker-compose run elixir /bin/sh -c "cd apps/domain && mix ecto.reset"
```

Stopping everything is easy too:

```bash
docker-compose down
```

## Useful commands for local testing and debugging

Connecting to an IEx interactive console:

```bash
❯ docker-compose run elixir /bin/sh -c "cd apps/domain && iex -S mix"
```

Connecting to a running api/web instance shell:

```bash
❯ docker exec -it firezone-api-1 sh
/app
```

Connecting to a running api/web instance to run Elixir code from them:

```bash
# Start all services in daemon mode (in background)
❯ docker-compose up -d --build

# Connect to a running API node
❯ docker exec -it firezone-api-1 bin/api remote
Erlang/OTP 25 [erts-13.1.4] [source] [64-bit] [smp:5:5] [ds:5:5:10] [async-threads:1]

Interactive Elixir (1.14.3) - press Ctrl+C to exit (type h() ENTER for help)
iex(api@127.0.0.1)1>

# Connect to a running Web node
❯ docker exec -it firezone-web-1 bin/web remote
Erlang/OTP 25 [erts-13.1.4] [source] [64-bit] [smp:5:5] [ds:5:5:10] [async-threads:1]

Interactive Elixir (1.14.3) - press Ctrl+C to exit (type h() ENTER for help)
iex(web@127.0.0.1)1>
```

From `iex` shell you can run any Elixir code, for example you can emulate a full
flow using process messages, just keep in mind that you need to run seeds before
executing this example:

```elixir
[gateway | _rest_gateways] = Domain.Repo.all(Domain.Gateways.Gateway)
:ok = Domain.Gateways.connect_gateway(gateway)

[relay | _rest_relays] = Domain.Repo.all(Domain.Relays.Relay)
relay_secret = Domain.Crypto.random_token()
:ok = Domain.Relays.connect_relay(relay, relay_secret)
```

Now if you connect and list resources there will be one online because there is
a relay and gateway online.

Some of the functions require authorization, here is how you can obtain a
subject:

```elixir
user_agent = "User-Agent: iOS/12.7 (iPhone) connlib/0.7.412"
remote_ip = {127, 0, 0, 1}

# For a client
context = %Domain.Auth.Context{type: :client, user_agent: user_agent, remote_ip: remote_ip}
{:ok, subject} = Domain.Auth.authenticate(client_token, context)

# For an admin user, imitating the browser session
context = %Domain.Auth.Context{type: :browser, user_agent: user_agent, remote_ip: remote_ip}
provider = Domain.Repo.get_by(Domain.Auth.Provider, adapter: :userpass)
identity = Domain.Repo.get_by(Domain.Auth.Identity, provider_id: provider.id, provider_identifier: "firezone@localhost.local")
token = Domain.Auth.create_token(identity, context, "", nil)
browser_token = Domain.Tokens.encode_fragment!(token)
{:ok, subject} = Domain.Auth.authenticate(browser_token, context)
```

Listing connected gateways, relays, clients for an account:

```elixir
account_id = "c89bcc8c-9392-4dae-a40d-888aef6d28e0"

%{
  gateways: Domain.Gateways.Presence.list("gateways:#{account_id}"),
  relays: Domain.Relays.Presence.list("relays:#{account_id}"),
  clients: Domain.Clients.Presence.list("clients:#{account_id}"),
}
```

### Connecting billing in dev mode for manual testing

Prerequisites:

- A Stripe account (Note: for the Firezone team, you will need to be invited to
  the Firezone Stripe account)
- [Stripe CLI](https://github.com/stripe/stripe-cli)

Steps:

1. Use static seeds to provision account ID that corresponds to staging setup on
   Stripe:

   ```bash
   STATIC_SEEDS=true mix do ecto.reset, ecto.seed
   ```

1. Start Stripe CLI webhook proxy:

   ```bash
   stripe listen --forward-to localhost:13001/integrations/stripe/webhooks
   ```

1. Start the Phoenix server with enabled billing from the [`elixir/`](./) folder
   using a [test mode token](https://dashboard.stripe.com/test/apikeys):

   ```bash
   cd elixir/
   BILLING_ENABLED=true STRIPE_SECRET_KEY="...copy from stripe dashboard..." STRIPE_WEBHOOK_SIGNING_SECRET="...copy from stripe cli tool.." mix phx.server
   ```

When updating the billing plan in stripe, use the
[Stripe Testing Docs](https://docs.stripe.com/testing#testing-interactively) for
how to add test payment info

### WorkOS integration

WorkOS is currently being used for JumpCloud directory sync integration. This
allows JumpCloud users to use SCIM on the JumpCloud side, rather than having to
give Firezone an admin JumpCloud API token.

#### Connecting WorkOS in dev mode for manual testing

If you are not planning to use the JumpCloud provider in your local development
setup, then no additional setup is needed. However, if you do need to use the
JumpCloud provider locally, you will need to obtain an API Key and Client ID
from the [WorkOS Dashboard](https://dashboard.workos.com/api-keys).

To obtain a WorkOS dashboard login, contact one of the following Firezone team
members:

- @jamilbk
- @bmanifold
- @AndrewDryga

Once you are able to login to the WorkOS Dashboard, make sure that you have
selected the 'Staging' environment within WorkOS. Navigate to the API Keys page
and use the `Create Key` button to obtain credentials.

After obtaining WorkOS API credentials, you will need to make sure they are set
in the environment ENVs when starting your local dev instance of Firezone. As an
example:

```bash
cd elixir/
WORKOS_API_KEY="..." WORKOS_CLIENT_ID="..." mix phx.server
```

### Acceptance tests

You can disable headless mode for the browser by adding

```elixir

  @tag debug: true
  feature ....
```

to the acceptance test that you are running.

## Connecting to a staging or production instance

We use Google Cloud Platform for all our staging and production infrastructure.
You'll need access to this env to perform the commands below; to request access
you need to complete the following process:

- Open a PR adding yourself to `project_owners` in `main.tf` for each of the
  [environments](../terraform/environments) you need access.
- Request a review from an existing project owner.
- Once approved, merge the PR and verify access by continuing with one of the
  steps below.

This is a danger zone so first of all, ALWAYS make sure on which environment
your code is running:

```bash
❯ gcloud config get project
firezone-staging
```

Then you want to figure out which specific instance you want to connect to:

```bash
❯ gcloud compute instances list
NAME      ZONE        MACHINE_TYPE   PREEMPTIBLE  INTERNAL_IP  EXTERNAL_IP  STATUS
api-b02t  us-east1-d  n1-standard-1               10.128.0.22               RUNNING
api-srkp  us-east1-d  n1-standard-1               10.128.0.23               RUNNING
web-51wd  us-east1-d  n1-standard-1               10.128.0.21               RUNNING
web-6k3n  us-east1-d  n1-standard-1               10.128.0.20               RUNNING
```

SSH into the host VM:

```bash
❯ gcloud compute ssh api-b02t --tunnel-through-iap
No zone specified. Using zone [us-east1-d] for instance: [api-b02t].
...

  ########################[ Welcome ]########################
  #  You have logged in to the guest OS.                    #
  #  To access your containers use 'docker attach' command  #
  ###########################################################


andrew@api-b02t ~ $ $(docker ps | grep klt- | head -n 1 | awk '{split($NF, arr, "-"); print "docker exec -it "$NF" bin/"arr[2]" remote";}')
Erlang/OTP 25 [erts-13.1.4] [source] [64-bit] [smp:1:1] [ds:1:1:10] [async-threads:1] [jit]

Interactive Elixir (1.14.3) - press Ctrl+C to exit (type h() ENTER for help)
iex(api@api-b02t.us-east1-d.c.firezone-staging.internal)1>
```

One-liner to connect to a running application container:

```bash
❯ gcloud compute ssh $(gcloud compute instances list | grep "web-" | tail -n 1 | awk '{ print $1 }') --tunnel-through-iap -- '$(docker ps | grep klt- | head -n 1 | awk '\''{split($NF, arr, "-"); print "docker exec -it " $NF " bin/" arr[2] " remote";}'\'')'

Interactive Elixir (1.15.2) - press Ctrl+C to exit (type h() ENTER for help)
iex(web@web-w2f6.us-east1-d.c.firezone-staging.internal)1>
```

### Quickly provisioning an account

Useful for onboarding beta customers. See the `Domain.Ops.provision_account/1`
function:

```elixir
iex> Domain.Ops.create_and_provision_account(%{
  name: "Customer Account",
  slug: "customer_account",
  admin_name: "Test User",
  admin_email: "test@firezone.localhost"
})
```

### Creating an account on staging instance using CLI

```elixir
❯ gcloud compute ssh web-3vmw --tunnel-through-iap

andrew@web-3vmw ~ $ docker ps --format json | jq '"\(.ID) \(.Image)"'
"09eff3c0ebe8 us-east1-docker.pkg.dev/firezone-staging/firezone/web:b9c11007a4e230ab28f0138afc98188b1956dfd3"

andrew@web-3vmw ~ $ docker exec -it 09eff3c0ebe8 bin/web remote
Erlang/OTP 26 [erts-14.0.2] [source] [64-bit] [smp:1:1] [ds:1:1:20] [async-threads:1] [jit]

Interactive Elixir (1.15.2) - press Ctrl+C to exit (type h() ENTER for help)

iex(web@web-3vmw.us-east1-d.c.firezone-staging.internal)1> {:ok, account} = Domain.Accounts.create_account(%{name: "Firezone", slug: "firezone"})
{:ok, ...}

iex(web@web-3vmw.us-east1-d.c.firezone-staging.internal)2> {:ok, email_provider} = Domain.Auth.create_provider(account, %{name: "Email (OTP)", adapter: :email, adapter_config: %{}})
{:ok, ...}

iex(web@web-3vmw.us-east1-d.c.firezone-staging.internal)3> {:ok, actor} = Domain.Actors.create_actor(account, %{type: :account_admin_user, name: "Andrii Dryga"})
{:ok, ...}

iex(web@web-3vmw.us-east1-d.c.firezone-staging.internal)4> {:ok, identity} = Domain.Auth.upsert_identity(actor, email_provider, %{provider_identifier: "a@firezone.dev", provider_identifier_confirmation: "a@firezone.dev"})
...

iex(web@web-3vmw.us-east1-d.c.firezone-staging.internal)5> context = %Domain.Auth.Context{type: :browser, user_agent: "User-Agent: iOS/12.7 (iPhone) connlib/0.7.412", remote_ip: {127, 0, 0, 1}}

iex(web@web-3vmw.us-east1-d.c.firezone-staging.internal)6> {:ok, identity} = Domain.Auth.Adapters.Email.request_sign_in_token(identity, context)
{:ok, ...}

iex(web@web-3vmw.us-east1-d.c.firezone-staging.internal)7> Domain.Mailer.AuthEmail.sign_in_link_email(identity) |> Domain.Mailer.deliver()
{:ok, %{id: "d24dbe9a-d0f5-4049-ac0d-0df793725a80"}}
```

### Obtaining admin subject on staging

```elixir

❯ gcloud compute ssh web-2f4j --tunnel-through-iap -- '$(docker ps | grep klt- | head -n 1 | awk '\''{split($NF, arr, "-"); print "docker exec -it " $NF " bin/" arr[2] " remote";}'\'')'
Erlang/OTP 26 [erts-14.0.2] [source] [64-bit] [smp:1:1] [ds:1:1:20] [async-threads:1] [jit]

Interactive Elixir (1.15.2) - press Ctrl+C to exit (type h() ENTER for help)

iex(web@web-2f4j.us-east1-d.c.firezone-staging.internal)1> account_id = "REPLACE_ME"
...

iex(web@web-2f4j.us-east1-d.c.firezone-staging.internal)2> context = %Domain.Auth.Context{type: :browser, user_agent: "User-Agent: iOS/12.7 (iPhone) connlib/0.7.412", remote_ip: {127, 0, 0, 1}}
...

iex(web@web-2f4j.us-east1-d.c.firezone-staging.internal)3> [actor | _] = Domain.Actors.Actor.Query.by_type(:account_admin_user) |> Domain.Actors.Actor.Query.by_account_id(account_id) |> Domain.Repo.all()
...

iex(web@web-2f4j.us-east1-d.c.firezone-staging.internal)4> [identity | _] = Domain.Auth.Identity.Query.by_actor_id(actor.id) |> Domain.Repo.all()
...

iex(web@web-2f4j.us-east1-d.c.firezone-staging.internal)5> token = Domain.Auth.create_token(identity, context, "", nil)
...

iex(web@web-2f4j.us-east1-d.c.firezone-staging.internal)6> browser_token = Domain.Tokens.encode_fragment!(token)
...

iex(web@web-2f4j.us-east1-d.c.firezone-staging.internal)7> {:ok, subject} = Domain.Auth.authenticate(browser_token, context)
```

### Rotate relay token

```elixir

iex(web@web-xxxx.us-east1-d.c.firezone-staging.internal)1> group = Domain.Repo.one!(Domain.Relays.Group.Query.global())
...

iex(web@web-xxxx.us-east1-d.c.firezone-staging.internal)2> {:ok, token} = Domain.Relays.create_token(group, %{})
...
```

## Connection to production Cloud SQL instance

Install
[`cloud-sql-proxy`](https://cloud.google.com/sql/docs/postgres/connect-instance-auth-proxy)
(eg. `brew install cloud-sql-proxy`) and run:

```bash
cloud-sql-proxy --auto-iam-authn "firezone-prod:us-east1:firezone-prod?address=0.0.0.0&port=9000"
```

Then you can connect to the PostgreSQL using `psql`:

```bash
# Use your work email as username to connect
PG_USER=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" | head -n 1)
psql "host=localhost port=9000 sslmode=disable dbname=firezone user=${PG_USER}"
```

If you have issues with credentials try refreshing the application default
token:

```bash
gcloud auth application-default login
```

### Connecting to Cloud SQL instance as the `firezone` user

Some operations like DROP'ing indexes to recreate them require you to connect as the table owner, which in our case is the `firezone` user.

The password for this user is randomly generated by Terraform, so to connect as this user you need to obtain the password
from the Application configuration inside a running elixir container.

First, [obtain an iex shell](#connecting-to-a-staging-or-production-instances), then view the password with:

```elixir
Application.get_env(:domain, Domain.Repo)
```

Now, you can connect to the Cloud SQL instance as the `firezone` user:

```bash
psql "host=localhost port=9000 sslmode=disable dbname=firezone user=firezone"
```

## Deploying

### Apply Terraform changes without deploying new containers

This can be helpful when you want to quickly iterate over Terraform configuration in staging environment, without
having to merge for every single apply attempt.

Switch to the staging environment:

```bash
cd terraform/environments/staging
```

and apply changes reusing previous container versions:

```bash
terraform apply -var image_tag=$(terraform output -raw image_tag)
```

### Deploying production

Before deploying, check if the `main` branch has any breaking changes since the last deployment. You can do this by comparing the `main` branch with the last deployed commit, which you can find [here](https://github.com/firezone/firezone/deployments/gcp_production).

Here is a one-liner to open the comparison in your browser:

```bash
open "https://github.com/firezone/firezone/compare/$(curl -L -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "https://api.github.com/repos/firezone/firezone/actions/workflows/deploy.yml/runs?status=completed&per_page=1" | jq -r '.workflow_runs[0].head_commit.id')...main"
```

If there are any breaking changes, make sure to confirm with the rest of the team on a rollout strategy before proceeding with any of the steps listed below.

Then, go to ["Deploy Production"](https://github.com/firezone/firezone/actions/workflows/deploy.yml) CI workflow and click "Run Workflow".

1. In the form that appears, read the warning and check the checkbox next to it.
2. The main branch is selected by default for deployment. To deploy a previous version, enter the commit SHA in the "Image tag to deploy" field.
   The commit MUST be from the `main` branch.
3. Click "Run Workflow" to start the process.

The workflow will run all the way till the `deploy-production` step (which runs `terraform apply`) and wait for an approval from one of the project owners,
message one of your colleagues to approve it.

#### Deployment Takes Too Long to Complete

Typically, `terraform apply` takes around 15 minutes in production. If it's taking longer (or you want to monitor the status), here are a few things you can check:

1. **Monitor the run status in [Terraform Cloud](https://app.terraform.io/app/firezone/workspaces/production/runs).**
2. **Check the status of Instance Groups in [Google Cloud Console](https://console.cloud.google.com/compute/instanceGroups/list?project=firezone-prod).**
3. [Check the logs](#viewing-logs) for the deployed instances.

For instance groups stuck in the `UPDATING` state:

- Open the group and look for any errors. Typically, if deployment is stuck, you'll find one instance in the group with an error (and a recent creation time), while the others are pending updates.
- To quickly view logs for that instance, click the instance name and then click the `Logging` link.

_Do not panic—our production environment should remain stable. GCP and Terraform are designed to keep old instances running until the new ones are healthy._

#### Common Reasons for Deployment Issues

**1. A Bug in the Code**

- This can either crash the instance or make it unresponsive (you’ll notice failing health checks and error logs).
- If this happens, ensure there were no database migrations as part of the changes (check `priv/repo/migrations`).
- If no migrations are involved, rollback the deployment. To do this, cancel the currently running deployment,
  find the last successful deployment in Terraform Cloud, copy the `image_tag` from its output, and run:

  ```bash
  cd terraform/environments/production
  terraform apply -var image_tag=<LAST_SUCCESSFUL_IMAGE_TAG_HERE>
  ```

- You can also rollback a specific component by overriding its image tag in the `terraform apply` command:

  ```bash
  terraform apply -var image_tag=<CURRENT_IMAGE_TAG> -var <COMPONENT_NAME>_image_tag=<LAST_SUCCESSFUL_IMAGE_TAG_HERE>
  ```

  _If there were migrations and they’ve already been applied, proceed to the next option._

**2. An Issue with the Migration**

- You’ll notice failing health checks and error logs related to the migration.
- You can either:
  - Fix the data causing the migration to fail (refer to [Connection to Production Cloud SQL Instance](#connection-to-production-cloud-sql-instance)).
  - Fix the migration code and redeploy.

**3. Insufficient Resources to Deploy New Instances**

- If there are no errors but updates are pending, there might not be enough resources to deploy new instances.
- This can be found in the Errors tab of the instance group.

  Typically, this issue resolves itself as old reservations are freed up.

## Monitoring and Troubleshooting

### Viewing logs

Logs can be viewed via th [Logs Explorer](https://console.cloud.google.com/logs)
in GCP, or via the `gcloud` CLI:

```bash
# First, login
> gcloud auth login

# Always make sure you're in the correct environment
> gcloud config get project
firezone-staging

# Now you can stream logs directly to your terminal.

############
# Examples #
############

# Stream all Elixir error logs:
> gcloud logging read "jsonPayload.message.severity=ERROR"

# Stream Web app logs (portal UI):
> gcloud logging read 'jsonPayload."cos.googleapis.com/container_name":web'

# Stream API app logs (connlib control plane):
> gcloud logging read 'jsonPayload."cos.googleapis.com/container_name":api'

# For more info on the filter expression syntax, see:
# https://cloud.google.com/logging/docs/view/logging-query-language
```

Here is a helpful filter to show all errors and crashes:

```
resource.type="gce_instance"
(severity>=ERROR OR "Kernel pid terminated" OR "Crash dump is being written")
-protoPayload.@type="type.googleapis.com/google.cloud.audit.AuditLog"
-logName:"/logs/GCEGuestAgent"
-logName:"/logs/OSConfigAgent"
-logName:"/logs/ops-agent-fluent-bit"
```

An alert will be sent to the `#feed-proudction` Slack channel when a new error is logged that matches this filter.
You can also see all errors in [Google Cloud Error Reporting](https://console.cloud.google.com/errors?project=firezone-prod).

Sometimes logs will not provide enough context to understand the issue. In those cases you can
try to filter by the `trace` field to get more information. Copy the `trace` value from a log entry
and use it in the filter:

```
resource.type="gce_instance"
jsonPayload.trace:"<trace_id>"
```

Note: If you simply click "Show entries for this trace" in the log entry, it will
automatically **append** the filter for you. You might want to remove rest of filters
so you can see all logs for that trace.

## Viewing metrics

Metrics can be viewed via the [Metrics Explorer](https://console.cloud.google.com/monitoring/metrics-explorer) in GCP.

## Viewing traces

Traces can be viewed via the [Trace Explorer](https://console.cloud.google.com/traces/list) in GCP.
They are mostly helpful for debugging Clients, Relays and Gateways.

For example, if you want to find all traces for client management processes, you can use the following filter:

```
RootSpan: client.connect
```

Then you can drill down either by using a `client_id: <ID>` or an `account_id: <ID>`.

Note: For WS API processes, the total trace duration might not be helpful since a single trace is defined for
the entire connection lifespan.
