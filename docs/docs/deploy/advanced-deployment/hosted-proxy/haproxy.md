```
root@ip-172-31-79-208:/home/ubuntu# cat /etc/haproxy/haproxy.cfg 
defaults
    mode http

frontend app1
    bind *:80
    option forwardfor
    default_backend             backend_app1

backend backend_app1
    server mybackendserver 127.0.0.1:13000
```