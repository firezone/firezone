#!/usr/bin/env bash

set -e

echo2() {
  echo $* >&2
}

CONTAINER_NAME=firezone-gateway
TARGET_IMAGE="${TARGET_IMAGE:-us-east1-docker.pkg.dev/firezone-prod/firezone/gateway:1}"          # use DOCKER_IMAGE to override default image

# find existing running gateway
CURRENTLY_RUNNING=$(docker ps --format "{{.Names}} {{.Image}}" | grep -e "$CONTAINER_NAME" | awk '{print $1}')
if [ "$CURRENTLY_RUNNING" == "" ]; then
    echo2 "No Firezone gateway found running on this system. Exiting."
    exit -1
fi

echo2 -n "Pulling latest image..."
docker pull "$TARGET_IMAGE" > /dev/null
echo2
echo2 "Checking for containers to upgrade..."
for RUNNING_CONTAINER in $CURRENTLY_RUNNING
do
    LATEST=$(docker inspect --format "{{.Id}}" "$TARGET_IMAGE")
    RUNNING=$(docker inspect --format "{{.Image}}" "$RUNNING_CONTAINER")

    # Upgrade if necessary
    if [ "$RUNNING" != "$LATEST" ]; then
        echo2 -n "Upgrading gateway..."
        docker container inspect "$RUNNING_CONTAINER" --format '{{join .Config.Env "\n"}}' | grep -v "PATH" > variables.env
        docker stop "$CONTAINER_NAME" > /dev/null
        docker rm -f "$CONTAINER_NAME" > /dev/null
        docker run -d \
          --restart=unless-stopped \
          --pull=always \
          --health-cmd="ip link | grep tun-firezone" \
          --name=firezone-gateway \
          --cap-add=NET_ADMIN \
          --volume /etc/firezone \
          --env-file variables.env \
          --sysctl net.ipv4.ip_forward=1 \
          --sysctl net.ipv4.conf.all.src_valid_mark=1 \
          --sysctl net.ipv6.conf.all.disable_ipv6=0 \
          --sysctl net.ipv6.conf.all.forwarding=1 \
          --sysctl net.ipv6.conf.default.forwarding=1 \
          --device="/dev/net/tun:/dev/net/tun" \
          "$TARGET_IMAGE"
        rm variables.env
        echo2 "Container upgraded"
    else
      echo2 "Gateway is already up to date"
    fi
done

echo2 "Done!"
