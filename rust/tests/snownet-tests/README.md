# snownet integration tests

This directory contains Docker-based integration tests for the `snownet` crate.
Each integration test setup is a dedicated docker-compose file.

## Running

To run one of these tests, use the following command:

```shell
sudo docker compose -f ./docker-compose.lan.yml up --exit-code-from dialer --abort-on-container-exit --build
```

This will force a re-build of the containers and exit with 0 if everything works correctly.

## Design

Each file consists of at least:

- A dialer
- A listener
- A redis server

Redis acts as the signalling channel.
Dialer and listener use it to exchange offers & answers as well as ICE candidates.

The various files simulate different network environments.
We use nftables to simulate NATs and / or force the use of TURN servers.
