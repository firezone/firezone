---
layout: default
title: Authenticate
nav_order: 3
has_children: true
has_toc: false
description: >
  This page contains all the authentication methods that Firezone supports.
---
---

Firezone provides the ability to require authentication to download device
configuration files. Firezone supports the following single sign on (SSO)
providers and authentication methods:

* [Google]({%link docs/authenticate/google-sso.md%})
* [Okta]({%link docs/authenticate/okta-sso.md%})
* [Local email/password authentication (default)]({%link docs/authenticate/web-auth.md%})

If you wish to use an OAuth provider that is not listed above,
please open a
[GitHub issue](https://github.com/firezone/firezone/issues).

Periodic re-authentication can be enforced by changing the setting in `settings/security`.
To re-authenticate a VPN session, a user will need to turn off their
VPN connection and log in to the Firezone portal (URL specified during
[deployment]({%link docs/deploy/prerequisites.md%})
).

![re-authenticate](https://user-images.githubusercontent.com/52545545/155812962-9b8688c1-00af-41e4-96c3-8fb52f840aed.gif){:width="600"}
