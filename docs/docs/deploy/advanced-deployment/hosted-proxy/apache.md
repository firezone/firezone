---
title: Example Apache configuration
sidebar_position: 5
---

The following are example apache2 configurations with and without SSL.

These expect the apache2 to be running on the same host as firezone and `default['firezone']['phoenix']['port']` to be `13000`.

### Without SSL

Take into account that having traffic directly incoming without SSL won't work you'll need at some point to terminate an SSL connection.

```
LoadModule rewrite_module /usr/lib/apache2/modules/mod_rewrite.so
LoadModule proxy_module /usr/lib/apache2/modules/mod_proxy.so
LoadModule proxy_http_module /usr/lib/apache2/modules/mod_proxy_http.so
LoadModule proxy_wstunnel_module /usr/lib/apache2/modules/mod_proxy_wstunnel.so
<VirtualHost *:80>
        ServerName <server-name>
        ProxyPreserveHost On
        ProxyPassReverse "/" "http://127.0.0.1:13000/"
        ProxyPass "/" "http://127.0.0.1:13000/"
        RewriteEngine on
        RewriteCond %{HTTP:Upgrade} websocket [NC]
        RewriteCond %{HTTP:Connection} upgrade [NC]
        RewriteRule ^/?(.*) "ws://127.0.0.1:13000/$1" [P,L]
</VirtualHost>
```

### With SSL

This configuration uses the generated self-signed certs

```
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
        ProxyPreserveHost On
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