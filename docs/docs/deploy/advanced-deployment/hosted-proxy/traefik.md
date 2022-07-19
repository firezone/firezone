You will need to add 

`default['firezone']['phoenix']['listen_address'] = '172.17.0.1'`

and:

`default['firezone']['trusted_proxy'] = ['172.18.0.2']`

`docker-compose.yml`:
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


SSL:

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
