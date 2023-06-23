# Welcome to Elixir-land!

This README provides an overview for running and managing Firezone's Elixir-based control plane.

## Running Control Plane for local development

You can use the [Top-Level Docker Compose](../docker-compose.yml) to start any services locally. The `web` and `api` compose services are built application releases that are pretty much the same as the ones we run in production, while the `elixir` compose service runs raw Elixir code, without a built release.

This means you'll want to use the `elixir` compose service to run Mix tasks and any Elixir code on-the-fly, but you can't do that in `web`/`api` so easily because Elixir strips out Mix and other tooling [when building an application release](https://hexdocs.pm/mix/Mix.Tasks.Release.html).

`elixir` additionally caches `_build` and `node_modules` to speed up compilation time and syncs
`/apps`, `/config` and other folders with the host machine.

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

# Start the API service for control plane sockets while listening to STDIN (where you will see all the logs)
❯ docker-compose up api --build
```

Now you can verify that it's working by connecting to a websocket:

<details>
  <summary>Gateway</summary>

```elixir
❯ websocat --header="User-Agent: iOS/12.7 (iPhone) connlib/0.7.412" "ws://127.0.0.1:8081/gateway/websocket?token=GATEWAY_TOKEN_FROM_SEEDS&external_id=thisisrandomandpersistent&name_suffix=kkX1&public_key=kceI60D6PrwOIiGoVz6hD7VYCgD1H57IVQlPJTTieUE="
```

</details>
<details>
  <summary>Relay</summary>

```elixir
❯ websocat --header="User-Agent: Linux/5.2.6 (Debian; x86_64) relay/0.7.412" "ws://127.0.0.1:8081/relay/websocket?token=RELAY_TOKEN_FROM_SEEDS&ipv4=24.12.79.100&ipv6=4d36:aa7f:473c:4c61:6b9e:2416:9917:55cc"

# Here is what you will see in docker logs firezone-api-1
# {"time":"2023-06-05T23:16:01.537Z","severity":"info","message":"CONNECTED TO API.Relay.Socket in 251ms\n  Transport: :websocket\n  Serializer: Phoenix.Socket.V1.JSONSerializer\n  Parameters: %{\"ipv4\" => \"24.12.79.100\", \"ipv6\" => \"4d36:aa7f:473c:4c61:6b9e:2416:9917:55cc\", \"stamp_secret\" => \"[FILTERED]\", \"token\" => \"[FILTERED]\"}","metadata":{"domain":["elixir"],"erl_level":"info"}}

# After this you need to join the `relay` topic and pass a `stamp_secret` in the payload.
# For details on this structure see https://hexdocs.pm/phoenix/Phoenix.Socket.Message.html
> {"event":"phx_join","topic":"relay","payload":{"stamp_secret":"makemerandomplz"},"ref":"unique_string_ref","join_ref":"unique_join_ref"}

{"event":"phx_reply","payload":{"response":{},"status":"ok"},"ref":"unique_string_ref","topic":"relay"}
{"event":"init","payload":{},"ref":null,"topic":"relay"}
```

</details>
<br />

You can reset the database (eg. when there is a migration that breaks data model for unreleased versions) using following command:

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

From `iex` shell you can run any Elixir code, for example you can emulate a full flow using process messages,
just keep in mind that you need to run seeds before executing this example:

```elixir
[gateway | _rest_gateways] = Domain.Repo.all(Domain.Gateways.Gateway)
:ok = Domain.Gateways.connect_gateway(gateway)

[relay | _rest_relays] = Domain.Repo.all(Domain.Relays.Relay)
relay_secret = Domain.Crypto.rand_string()
:ok = Domain.Relays.connect_relay(relay, relay_secret)
```

Now if you connect and list resources there will be one online because there is a relay and gateway online.

Some of the functions require authorization, here is how you can obtain a subject:

```elixir
user_agent = "User-Agent: iOS/12.7 (iPhone) connlib/0.7.412"
remote_ip = {127, 0, 0, 1}

# For a client
{:ok, subject} = Domain.Auth.sign_in(client_token, user_agent, remote_ip)

# For an admin user
provider = Domain.Repo.get_by(Domain.Auth.Provider, adapter: :userpass)
identity = Domain.Repo.get_by(Domain.Auth.Identity, provider_id: provider.id, provider_identifier: "firezone@localhost")
subject = Domain.Auth.build_subject(identity, nil, user_agent, remote_ip)
```

## Connecting to a staging or production instances

We use Google Cloud Platform for all our staging and production infrastructure. You'll need access to this env to perform the commands below; to get and access you need to add yourself to `project_owners` in `main.tf` for each of the [environments](../terraform/environments).

This is a danger zone so first of all, ALWAYS make sure on which environment your code is running:

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

SSH into the VM and enter remote Elixir shell:

```bash
❯ gcloud compute ssh api-b02t
No zone specified. Using zone [us-east1-d] for instance: [api-b02t].
...

  ########################[ Welcome ]########################
  #  You have logged in to the guest OS.                    #
  #  To access your containers use 'docker attach' command  #
  ###########################################################

andrew@api-b02t ~ $ docker ps --format json | jq '"\(.ID) \(.Image)"'
"1ab7d7c6878c - us-east1-docker.pkg.dev/firezone-staging/firezone/api:branch-andrew_deployment"

andrew@api-b02t ~ $ docker exec -it 1ab7d7c6878c bin/api remote
Erlang/OTP 25 [erts-13.1.4] [source] [64-bit] [smp:1:1] [ds:1:1:10] [async-threads:1] [jit]

Interactive Elixir (1.14.3) - press Ctrl+C to exit (type h() ENTER for help)
iex(api@api-b02t.us-east1-d.c.firezone-staging.internal)1>
```
