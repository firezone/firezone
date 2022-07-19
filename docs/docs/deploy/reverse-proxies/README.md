---
title: Change Reverse Proxy
sidebar_position: 4
---

**Warning:** This is an advanced configuration and not needed to have a functional Firezone instance. There are important security risks when not set up correctly.

## Introduction

Firezone comes with a bundled [Nginx](https://www.nginx.com/) reverse-proxy, however, in some cases you might want to deploy your own server such as when using behind your own load-balancer.

## Requisites

Below you will find the requirements in order to setup firezone and the reverse-proxies.

### Firezone requisites

* Disable the bundled Nginx by setting `default['firezone']['nginx']['enabled']` to `false` in the config file.
* Add all intermediate proxies IPs to `default['firezone']['trusted_proxy']`, this is used to calculate the actual client ip and prevent spoofing.
* Make sure `default['firezone']['proxy_fowrarded']` is set to `true`.

Read more about the configuration options [here](../../../reference/configuration-file.md).

### Proxy requisites

* All your proxies need to configure the `x-forwarded-for` header as explained [here](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/X-Forwarded-For) and `x-proto` for https.
* One of your proxies must terminate SSL since we enforce [secure cookies](https://developer.mozilla.org/en-US/docs/Web/HTTP/Cookies#restrict_access_to_cookies).
* You need to reverse-proxy all http traffic and WS.


## Security considerations

Since the Firezone app expects plain HTTP traffic the proxy will send non-encrypted requests to the server. This open up that communication to be sniffed and spoofed. So, if you can't absolutely trust every point of the connection between Firezone and the proxy you should make sure there is a proxy terminating SSL in the same host as the app to prevent this.


## Example configurations

* [Apache](../reverse-proxies/apache.md)
* [Traefik](../reverse-proxies/traefik.md)
* [HAProxy](../reverse-proxies/haproxy.md)

These configurations are writen to be as simple as possible and just as an example, you'll probably want to further customize them.

If you have a working configuration for a different reverse-proxy or a different version of an existing one we appreciate any [contribution](https://github.com/firezone/firezone) to expand the examples for the community.
