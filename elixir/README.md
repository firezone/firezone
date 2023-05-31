# Welcome to Elixir-land!

## Running Control Plane for local development

You can use [Top-Level Docker Compose](../docker_compose.yml) and start any released Elixir
app:

```bash
docker-compose build

# Create the database
# Hint: you can run any mix commands like this,
# eg. mix ecto.reset will reset your database
docker-compose run mix /bin/sh -c "cd apps/domain && mix ecto.create"

# Ensure database is migrated before running seeds
docker-compose run api bin/migrate

# Seed the database
# Hint: some access tokens will be generated and written to stdout,
# don't forget to save them for later
docker-compose run api bin/seed

# Start the API service for control plane sockets
# (You can start web too.)
docker-compose up api

# Verify it's working
websocat --header="User-Agent: iOS/12.7 (iPhone) connlib/0.7.412" "ws://127.0.0.1:13001/gateway/websocket?token=SFMyNTY.g2gDaAJtAAAAJGJjZjBhNWExLTQxY2QtNDllNi1iNjcwLTc2NTBlNWNlZTY3N20AAABAWDktRFBJM0RlM3V6bTNtVFFyRDZwX1FjVHEtZWdZNF9GYk1LdTFXMGpBblpBdWE1UWVNWWJPS3VzWWZ0Tm5XMm4GAAuMPm-IAWIAAVGA.t6IJx1-WtHziQ89jQh6TTj5OA-Rjwwsa6dHYhgQ8p8A&external_id=thisisrandom&name_suffix=kk&public_key=kceI60D6PrwOIiGoVz6hD7VYCgD1H57IVQlPJTTieUE="
```
