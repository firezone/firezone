#!/bin/sh

docker compose -f ./docker-compose.e2e.yml run firezone /bin/sh -c "exec mix eval FzHttp.Release.create_admin_user"
export API_TOKEN=$(docker compose -f ./docker-compose.e2e.yml run firezone /bin/sh -c "exec mix eval FzHttp.Release.create_api_token" | tail -1)
docker compose -f ./docker-compose.e2e.yml run e2e_orchestrator