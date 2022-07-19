---
title: Traefik
sidebar_position: 2
---

The following are examples for configuring the [Traefik](https://traefik.io/) proxy.

As of right now Firezone can't be run as a container in production, although this is a [planned feature](https://github.com/firezone/firezone/issues/260). So, these example configurations expects Firezone to be deployed in the same host as the proxy.

In these configurations we assume `default['firezone']['phoenix']['port']` to be `13000`. Furthermore, for these configuration to work we need the Firezone app to listen in the Docker interface so you should set:

* `default['firezone']['phoenix']['listen_address'] = '172.17.0.1'`
* `default['firezone']['trusted_proxy'] = ['172.18.0.2']`

In the [configuration file](../../reference/configuration-file.md).

## Without SSL termination

Take into account that a previous proxy will need to terminate SSL connections.

Set the following files

### `docker-compose.yml`
```
ubuntu@ip-172-31-79-208:~/traefik$ cat docker-compose.yml
version: '3'

services:
  reverse-proxy:
          #network_mode: "host"
    # The official v2 Traefik docker image
    image: traefik:v2.8
    # Enables the web UI and tells Traefik to listen to docker
    command:
    - "--providers.docker"
    - "--providers.file.filename=rules.yml"
    - "--entrypoints.web.address=:80"
    - "--entrypoints.web.forwardedHeaders.insecure"
    - "--log.level=DEBUG"
    extra_hosts:
    - "host.docker.internal:host-gateway"
    ports:
      # The HTTP port
      - "80:80"
    volumes:
      # So that Traefik can listen to the Docker events
      - /var/run/docker.sock:/var/run/docker.sock
      - "./rules.yml:/rules.yml"
```

### `rules.yml`
```
ubuntu@ip-172-31-79-208:~/traefik$ cat rules.yml
http:
  routers:
    test:
      entryPoints:
              - "web"
      service: test
      rule: "Host(`44.200.42.78`)"
  services:
    test:
      loadBalancer:
        servers:
        - url: "http://host.docker.internal:13000"
```

And then you can start the Traefik proxy with `docker compose up`

## With SSL termination

This configuration use the auto-generated Firezone self-signed certs as the default certificates for SSL.

### `docker-compose.yml`
```
version: '3'

services:
  reverse-proxy:
          #network_mode: "host"
    # The official v2 Traefik docker image
    image: traefik:v2.8
    # Enables the web UI and tells Traefik to listen to docker
    command:
    - "--providers.docker"
    - "--providers.file.filename=rules.yml"
    - "--entrypoints.web.address=:443"
    - "--entrypoints.web.forwardedHeaders.insecure"
    - "--log.level=DEBUG"
    extra_hosts:
    - "host.docker.internal:host-gateway"
    ports:
      # The HTTP port
      - "443:443"
    volumes:
      # So that Traefik can listen to the Docker events
      - /var/run/docker.sock:/var/run/docker.sock
      - "./rules.yml:/rules.yml"
      - /var/opt/firezone/ssl/ca:/ssl:ro
```

### `rules.yml`
```
http:
  routers:
    test:
      entryPoints:
        - "web"
      service: test
      rule: "Host(`44.200.42.78`)"
      tls: {}
  services:
    test:
      loadBalancer:
        servers:
        - url: "http://host.docker.internal:13000"
tls:
  stores:
    default:
      defaultCertificate:
        certFile: /ssl/ip-172-31-79-208.ec2.internal.crt
        keyFile: /ssl/ip-172-31-79-208.ec2.internal.key
```
