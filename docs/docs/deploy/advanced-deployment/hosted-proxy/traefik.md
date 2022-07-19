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
    - "--api.insecure=true" 
    - "--providers.docker"
    - "--providers.file.filename=rules.yml"
    - "--entrypoints.web.address=:80"
    - "--log.level=DEBUG"
    extra_hosts:
    - "host.docker.internal:host-gateway"
    ports:
      # The HTTP port
      - "80:80"
      # The Web UI (enabled by --api.insecure=true)
      - "8080:8080"
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