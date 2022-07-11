nginx:
1. disable nginx
2. install nginx
3. create /etc/nginx/sites-enabled/my.domain

```
upstream phoenix {
  server 127.0.0.1:13000 max_fails=5 fail_timeout=60s;
}
server {
  server_name my.domain;
  listen 80;
  location / {
    allow all;
    # Proxy Headers
    proxy_http_version 1.1;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header Host $http_host;
    proxy_set_header X-Cluster-Client-Ip $remote_addr;
    # The Important Websocket Bits!
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_pass http://phoenix;
  }
}
```

4. service nginx restart

Apache:

a2ensite acme-test

/etc/apache/sites-enabled/acme-test.conf

a2enmod rewrite
a2enmod proxy_wstunnel
a2enmod proxy
a2enmod proxy_http

```
LoadModule rewrite_module /usr/lib/apache2/modules/mod_rewrite.so
LoadModule proxy_module /usr/lib/apache2/modules/mod_proxy.so
LoadModule proxy_http_module /usr/lib/apache2/modules/mod_proxy_http.so
LoadModule proxy_wstunnel_module /usr/lib/apache2/modules/mod_proxy_wstunnel.so
<VirtualHost *:80>
        ServerName acme-test.firez.one
        ProxyPreserveHost On
        ProxyPassReverse "/" "http://127.0.0.1:13000/"
        ProxyPass "/" "http://127.0.0.1:13000/"
        RewriteEngine on
        RewriteCond %{HTTP:Upgrade} websocket [NC]
        RewriteCond %{HTTP:Connection} upgrade [NC]
        RewriteRule ^/?(.*) "ws://127.0.0.1:13000/$1" [P,L]
</VirtualHost>
```



```
LoadModule rewrite_module /usr/lib/apache2/modules/mod_rewrite.so
LoadModule proxy_module /usr/lib/apache2/modules/mod_proxy.so
LoadModule proxy_http_module /usr/lib/apache2/modules/mod_proxy_http.so
LoadModule proxy_wstunnel_module /usr/lib/apache2/modules/mod_proxy_wstunnel.so
LoadModule ssl_module /usr/lib/apache2/modules/mod_ssl.so
LoadModule headers_module /usr/lib/apache2/modules/mod_headers.so
Listen 443
<VirtualHost *:443>
        ServerName acme-test.firez.one
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
