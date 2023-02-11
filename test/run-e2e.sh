#!/bin/sh

docker compose run firezone /bin/sh -c "exec mix eval FzHttp.Release.create_admin_user"
export API_TOKEN=$(docker compose run firezone /bin/sh -c "exec mix eval FzHttp.Release.create_api_token" | tail -1)
docker compose run e2e_orchestrator
