---
title: Apache
sidebar_position: 1
---

The following are example [apache](https://httpd.apache.org/) configurations
with and without SSL termination.

These expect the apache to be running on the same host as firezone and
`default['firezone']['phoenix']['port']` to be `13000`.

### Without SSL termination

Take into account that a previous proxy will need to terminate SSL connections.

`<server-name>` needs to be replaced with your domain name.

This configuration needs to be placed in
`/etc/sites-available/<server-name>.conf`

and activated with `a2ensite <server-name>`

```conf
LoadModule rewrite_module /usr/lib/apache2/modules/mod_rewrite.so
LoadModule proxy_module /usr/lib/apache2/modules/mod_proxy.so
LoadModule proxy_http_module /usr/lib/apache2/modules/mod_proxy_http.so
LoadModule proxy_wstunnel_module /usr/lib/apache2/modules/mod_proxy_wstunnel.so
<VirtualHost *:80>
        ServerName <server-name>
        ProxyPassReverse "/" "http://127.0.0.1:13000/"
        ProxyPass "/" "http://127.0.0.1:13000/"
        RewriteEngine on
        RewriteCond %{HTTP:Upgrade} websocket [NC]
        RewriteCond %{HTTP:Connection} upgrade [NC]
        RewriteRule ^/?(.*) "ws://127.0.0.1:13000/$1" [P,L]
</VirtualHost>
```

### With SSL termination

This configuration should be used exactly like the previous and uses Firezone's
generated self-signed certs to terminate SSL.

```conf
LoadModule rewrite_module /usr/lib/apache2/modules/mod_rewrite.so
LoadModule proxy_module /usr/lib/apache2/modules/mod_proxy.so
LoadModule proxy_http_module /usr/lib/apache2/modules/mod_proxy_http.so
LoadModule proxy_wstunnel_module /usr/lib/apache2/modules/mod_proxy_wstunnel.so
LoadModule ssl_module /usr/lib/apache2/modules/mod_ssl.so
LoadModule headers_module /usr/lib/apache2/modules/mod_headers.so
Listen 443
<VirtualHost *:443>
        ServerName <server-name>
        RequestHeader set X-Forwarded-Proto "https"
        ProxyPassReverse "/" "http://127.0.0.1:13000/"
        ProxyPass "/" "http://127.0.0.1:13000/"
        RewriteEngine on
        RewriteCond %{HTTP:Upgrade} websocket [NC]
        RewriteCond %{HTTP:Connection} upgrade [NC]
        RewriteRule ^/?(.*) "ws://127.0.0.1:13000/$1" [P,L]
        SSLEngine On
        SSLCertificateFile "/var/opt/firezone/ssl/ca/acme-test.firez.one.crt"
        SSLCertificateKeyFile "/var/opt/firezone/ssl/ca/acme-test.firez.one.key"
</VirtualHost>
```
