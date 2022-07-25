---
title: HAProxy
sidebar_position: 3
---

The following is an example configuration for the
[HAProxy](https://www.haproxy.org/) proxy. we assume
`default['firezone']['phoenix']['port']` to be `13000` and the proxy running on
the same host as the Firezone app.

There is not SSL termination in this configuration so a previous proxy will
need to terminate the SSL connection.

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
