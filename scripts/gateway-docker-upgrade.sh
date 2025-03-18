#!/usr/bin/env bash

set -eu

TARGET_IMAGE="ghcr.io/firezone/gateway:1"

CURRENTLY_RUNNING=$(docker ps --format "{{.Names}} {{.Image}}" | grep -e "$TARGET_IMAGE" | awk '{print $1}')
if [ "$CURRENTLY_RUNNING" == "" ]; then
    echo "No Firezone gateway found running on this system. Exiting."
    exit 1
fi

echo "Pulling latest image..."
docker pull "$TARGET_IMAGE" >/dev/null
echo "Checking for containers to upgrade..."
for RUNNING_CONTAINER in $CURRENTLY_RUNNING; do
    LATEST=$(docker inspect --format "{{.Id}}" "$TARGET_IMAGE")
    RUNNING=$(docker inspect --format "{{.Image}}" "$RUNNING_CONTAINER")
    RUNNING_NAME=$(docker inspect --format "{{.Name}}" "$RUNNING_CONTAINER" | sed 's~/~~g')

    # Upgrade if necessary
    if [ "$RUNNING" != "$LATEST" ]; then
        echo -n "Upgrading gateway..."

        # Extract the environment variables from the running container
        docker container inspect "$RUNNING_CONTAINER" --format '{{join .Config.Env "\n"}}' | grep -v "PATH" >variables.env

        # Due to issues like https://github.com/firezone/firezone/issues/8471 we prefer to use the FIREZONE_ID
        # env var instead of volume-mapped id files on all deployment methods. This attempts to migrate the
        # FIREZONE_ID from the running container and set it as an env var in the new container.
        FILE_FIREZONE_ID=$(docker exec "$RUNNING_CONTAINER" cat /var/lib/firezone/gateway_id)
        if [ -n "$FILE_FIREZONE_ID" ]; then
            # Replace FIREZONE_ID in variables.env if variables.env contains FIREZONE_ID
            if grep -q "^FIREZONE_ID=" variables.env; then
                sed -i "s/FIREZONE_ID=.*/FIREZONE_ID=$FILE_FIREZONE_ID/" variables.env
            else
                echo "FIREZONE_ID=$FILE_FIREZONE_ID" >>variables.env
            fi
        else
            # Generate a new FIREZONE_ID if not found
            if ! grep -q "^FIREZONE_ID=" variables.env; then
                echo "FIREZONE_ID=$(uuidgen)" >>variables.env
            fi
        fi

        docker stop "$RUNNING_CONTAINER" >/dev/null
        docker rm -f "$RUNNING_CONTAINER" >/dev/null
        docker run -d \
            --restart=unless-stopped \
            --pull=always \
            --health-cmd="ip link | grep tun-firezone" \
            --name="$RUNNING_NAME" \
            --cap-add=NET_ADMIN \
            --env-file variables.env \
            --sysctl net.ipv4.ip_forward=1 \
            --sysctl net.ipv4.conf.all.src_valid_mark=1 \
            --sysctl net.ipv6.conf.all.disable_ipv6=0 \
            --sysctl net.ipv6.conf.all.forwarding=1 \
            --sysctl net.ipv6.conf.default.forwarding=1 \
            --device="/dev/net/tun:/dev/net/tun" \
            "$TARGET_IMAGE"
        rm variables.env
        echo "Container upgraded"
    else
        echo "Gateway is already up to date"
    fi
done

echo "Done!"
