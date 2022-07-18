---
title: Deploy your own proxy
sidebar_position: 4
---

**Warning: ** This is an advanced configuration and not needed to have a functional Firezone instance and there are important security concerns when set up incorrectly.

Firezone comes bundled with a [Nginx](https://www.nginx.com/) reverse-proxy, however, in some cases you might want to deploy your own server such as when using behind your own load-balancer.

To achieve this you need to:
* Disable the bundled Nginx by chnging `default['firezone']['nginx']['enabled']` to `false` in the config file, read more [here](../../../reference/configuration-file.md).
* Add all intermediate proxies to `default['firezone']['trusted_proxy']`, this is used to calculate the actual client ip and prevent spoofing. Read more [here](../../../reference/configuration-file.md).

After this you're ready to deploy your own proxy, keep in mind the following:
* All your proxies need to configure the `x-forwarded-for` header, preserve the `Host` header and `x-proto` for https.
* One of your proxies must terminate SSL since we expect [secure cookies](https://developer.mozilla.org/en-US/docs/Web/HTTP/Cookies#restrict_access_to_cookies).
* You need to reverse-proxy all http traffic and WS.


### Security considerations

Since Firezone app server expect http traffic the proxy will communicate using plain http with Firezone. This open up that communication to be spoofed and sniffed. So if you can't absolutely trust any point of the connection between Firezone and the proxy you should make sure there is a proxy server running on the host using SSL to prevent directly exposing the Firezone app. 