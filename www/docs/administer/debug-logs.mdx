---
title: Debug Logs
sidebar_position: 8
description:
  Docker deployments of Firezone generate and store debug logs to a JSON
  file on the host machine.
---

:::note
This article is written for Docker based deployments of Firezone.
:::

Docker deployments of Firezone consist of 3 running containers:

| Container | Function      | Example logs                                  |
| --------- | ------------- | --------------------------------------------- |
| firezone  | Web portal    | HTTP requests received and responses provided |
| postgres  | Database      |                                               |
| caddy     | Reverse proxy |                                               |

Each container generates and stores logs to a JSON file on the host
machine. These files can be found at
`var/lib/docker/containers/{CONTAINER_ID}/{CONTAINER_ID}-json.log`.

Run the `docker compose logs` command to view the log output from all running
containers. Note, `docker compose` commands need to be run in the Firezone
root directory. This is `$HOME/.firezone` by default.

See additional options of the `docker compose logs` command
[here](https://docs.docker.com/engine/reference/commandline/compose_logs/).

## Managing and configuring Docker logs

By default, Firezone uses the `json-file` logging driver without
[additional configuration](https://docs.docker.com/config/containers/logging/json-file/).
This means logs from each container are individually stored in a file format
designed to be exclusively accessed by the Docker daemon. Log rotation is not
enabled, so logs on the host can build up and consume excess storage space.

For production deployments of Firezone you may want to configure how logs are
collected and stored. Docker provides
[multiple mechanisms](https://docs.docker.com/config/containers/logging/configure/)
to collect information from running containers and services.

Examples of popular plugins, configurations, and use cases are:

- Export container logs to your SIEM or observability platform (i.e.
  [Splunk](https://docs.docker.com/config/containers/logging/splunk/)
  or
  [Google Cloud Logging](https://docs.docker.com/config/containers/logging/gcplogs/)
  )
- Enable log rotation and max file size.
- [Customize log driver output](https://docs.docker.com/config/containers/logging/log_tags/)
  with tags.
