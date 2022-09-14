---
title: HAProxy
sidebar_position: 3
---

The following is an example reverse proxy configuration for [HAProxy](
https://www.haproxy.org/) proxy. We assume
`default['firezone']['phoenix']['port']` to be `13000` and the proxy running on
the same host as the Firezone app.

Since Firezone requires HTTPS for the web portal, please bear in mind a
downstream proxy will need to terminate SSL connections in this scenario.

You can also configure HAProxy to handle the SSL termination as explained
[here](https://www.haproxy.com/blog/haproxy-ssl-termination/) but take into
account that the `pem` file expected by `ssl crt` option needs to contain
both the `crt` and `key` file.

`/etc/haproxy/haproxy.cfg`:

```conf
defaults
    mode http

frontend app1
    bind *:80
    option forwardfor
    default_backend             backend_app1

backend backend_app1
    server mybackendserver 127.0.0.1:13000
```
