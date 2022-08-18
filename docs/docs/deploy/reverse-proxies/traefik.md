---
title: Traefik
sidebar_position: 2
---

The following are examples for configuring the [Traefik](https://traefik.io/)
proxy as a reverse proxy for Firezone.

In these examples, we assume Traefik is deployed using Docker on the same host
as Firezone. For this to work, you'll need to make sure Firezone's phoenix
app is bound to port `13000` on the Docker interface address and
`external_trusted_proxies` is set properly:

```ruby
# /etc/firezone/firezone.rb

# ...

default['firezone']['phoenix']['port'] = 13000
default['firezone']['phoenix']['listen_address'] = '172.17.0.1'
default['firezone']['external_trusted_proxies'] = ['172.18.0.2']
```

## Without SSL termination

Since Firezone requires HTTPS for the web portal, please bear in mind a
downstream proxy will need to terminate SSL connections in this scenario.

Use the following `docker-compose.yml` and `rules.yml` files to configure
Traefik:

### `docker-compose.yml`

```yaml
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

```yaml
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

Now you should be able to start the Traefik proxy with `docker compose up`.

## With SSL termination

This configuration uses Firezone's auto-generated self-signed certificates.

### `docker-compose.yml`

```yaml
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

```yaml
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
        certFile: /path/to/your/cert.crt
        keyFile: /path/to/your/key.key
```
