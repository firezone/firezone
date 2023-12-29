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
❯ export GATEWAY_TOKEN_FROM_SEEDS="SFMyNTY.g2gDaAJtAAAAJDNjZWYwNTY2LWFkZmQtNDhmZS1hMGYxLTU4MDY3OTYwOGY2Zm0AAABAamp0enhSRkpQWkdCYy1vQ1o5RHkyRndqd2FIWE1BVWRwenVScjJzUnJvcHg3NS16bmhfeHBfNWJUNU9uby1yYm4GAJXr4emIAWIAAVGA.jz0s-NohxgdAXeRMjIQ9kLBOyd7CmKXWi2FHY-Op8GM"

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
❯ export RELAY_TOKEN_FROM_SEEDS="SFMyNTY.g2gDaAJtAAAAJDcyODZiNTNkLTA3M2UtNGM0MS05ZmYxLWNjODQ1MWRhZDI5OW0AAABARVg3N0dhMEhLSlVWTGdjcE1yTjZIYXRkR25mdkFEWVFyUmpVV1d5VHFxdDdCYVVkRVUzbzktRmJCbFJkSU5JS24GAMDq4emIAWIAAVGA.fLlZsUMS0VJ4RCN146QzUuINmGubpsxoyIf3uhRHdiQ"

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
❯ export CLIENT_TOKEN_FROM_SEEDS="SFMyNTY.g2gDaAN3CGlkZW50aXR5bQAAACQ3ZGE3ZDFjZC0xMTFjLTQ0YTctYjVhYy00MDI3YjlkMjMwZTV3Bmlnbm9yZW4GAJhGr7WKAWIACTqA.mrPu5eFVwkfRml7zzHb5uYfosLGaYVHq03-wE02xUNc"

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
❯ {"event":"prepare_connection","topic":"client","payload":{"resource_id":"116c62dc-bae5-45b0-afa2-4afe7f195144"},"ref":"unique_prepare_connection_ref"}

{"ref":"unique_prepare_connection_ref","topic":"client","event":"phx_reply","payload":{"status":"ok","response":{"relays":[{"type":"stun","uri":"stun:172.28.0.101:3478"},{"type":"turn","username":"1719090081:UVxHhieTJWaD8_Sg","password":"Ml65XDZyYpuBiEIvk/q0Zy6EEJ1ZwGa4pWztXFP+tOo","uri":"turn:172.28.0.101:3478","expires_at":1719090081}],"resource_id":"4429d3aa-53ea-4c03-9435-4dee2899672b"}}}

# Initiate connection to a resource
❯ {"event":"request_connection","topic":"client","payload":{"resource_id":"4429d3aa-53ea-4c03-9435-4dee2899672b","client_payload":"RTC_SD","client_preshared_key":"+HapiGI5UdeRjKuKTwk4ZPPYpCnlXHvvqebcIevL+2A="},"ref":"unique_request_connection_ref"}

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
{:ok, subject} = Domain.Auth.sign_in(client_token, %Domain.Auth.Context{type: :client, user_agent: user_agent, remote_ip: remote_ip})

# For an admin user
provider = Domain.Repo.get_by(Domain.Auth.Provider, adapter: :userpass)
identity = Domain.Repo.get_by(Domain.Auth.Identity, provider_id: provider.id, provider_identifier: "firezone@localhost")
subject = Domain.Auth.build_subject(identity, nil, %Domain.Auth.Context{type: :browser, user_agent: user_agent, remote_ip: remote_ip})
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

## Connecting to a staging or production instances

We use Google Cloud Platform for all our staging and production infrastructure.
You'll need access to this env to perform the commands below; to get and access
you need to add yourself to `project_owners` in `main.tf` for each of the
[environments](../terraform/environments).

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
iex> Domain.Ops.provision_account(%{account_name: "Customer Account", account_slug: "customer_account", account_admin_name: "Test User", account_admin_email: "test@firezone.localhost"})
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

iex(web@web-3vmw.us-east1-d.c.firezone-staging.internal)2> {:ok, magic_link_provider} = Domain.Auth.create_provider(account, %{name: "Email", adapter: :email, adapter_config: %{}})
{:ok, ...}

iex(web@web-3vmw.us-east1-d.c.firezone-staging.internal)3> {:ok, actor} = Domain.Actors.create_actor(account, %{type: :account_admin_user, name: "Andrii Dryga"})
{:ok, ...}

iex(web@web-3vmw.us-east1-d.c.firezone-staging.internal)4> {:ok, identity} = Domain.Auth.upsert_identity(actor, magic_link_provider, %{provider_identifier: "a@firezone.dev", provider_identifier_confirmation: "a@firezone.dev"})
...

iex(web@web-3vmw.us-east1-d.c.firezone-staging.internal)5> {:ok, identity} = Domain.Auth.Adapters.Email.request_sign_in_token(identity)
{:ok, ...}

iex(web@web-3vmw.us-east1-d.c.firezone-staging.internal)6> Web.Mailer.AuthEmail.sign_in_link_email(identity) |> Web.Mailer.deliver()
{:ok, %{id: "d24dbe9a-d0f5-4049-ac0d-0df793725a80"}}
```

### Obtaining admin subject on staging

```elixir

❯ gcloud compute ssh web-2f4j --tunnel-through-iap -- '$(docker ps | grep klt- | head -n 1 | awk '\''{split($NF, arr, "-"); print "docker exec -it " $NF " bin/" arr[2] " remote";}'\'')'
Erlang/OTP 26 [erts-14.0.2] [source] [64-bit] [smp:1:1] [ds:1:1:20] [async-threads:1] [jit]

Interactive Elixir (1.15.2) - press Ctrl+C to exit (type h() ENTER for help)

iex(web@web-2f4j.us-east1-d.c.firezone-staging.internal)1> [actor | _] = Domain.Actors.Actor.Query.by_type(:account_admin_user) |> Domain.Actors.Actor.Query.by_account_id("ACCOUNT_ID") |> Domain.Repo.all()
...

iex(web@web-2f4j.us-east1-d.c.firezone-staging.internal)2> [identity | _] = Domain.Auth.Identity.Query.by_actor_id(actor.id) |> Domain.Repo.all()
...

iex(web@web-2f4j.us-east1-d.c.firezone-staging.internal)3> subject = Domain.Auth.build_subject(identity, nil, %Domain.Auth.Context{type: :browser, user_agent: "CLI", remote_ip: {127, 0, 0, 1}})
```

### Rotate relay token

```elixir

iex(web@web-xxxx.us-east1-d.c.firezone-staging.internal)1> # select group to update
...

iex(web@web-xxxx.us-east1-d.c.firezone-staging.internal)2> {:ok, %{tokens: [token]}} = %{group | tokens: []} |> Domain.Repo.preload(:account) |> Domain.Relays.Group.Changeset.update(%{tokens: [%{}]}) |> Domain.Repo.update()

iex(web@web-xxxx.us-east1-d.c.firezone-staging.internal)3> Domain.Relays.encode_token!(token)
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

## Viewing logs

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
