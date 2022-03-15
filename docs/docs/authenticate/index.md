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

Periodic re-authentication can be enforced by changing the setting in
`settings/security`. This can be used to ensure a user must sign in to Firezone
periodically in order to maintain their VPN session.

You can set the session length to a minimum of 1 hour and maximum of 90 days.
Setting this to Never disables this setting, allowing VPN sessions indefinitely.
This is the default.

To re-authenticate an expired VPN session, a user will need to turn off their
VPN session and sign in to the Firezone portal (URL specified during
[deployment]({%link docs/deploy/prerequisites.md%})
).

![re-authenticate](https://user-images.githubusercontent.com/52545545/155812962-9b8688c1-00af-41e4-96c3-8fb52f840aed.gif){:width="600"}
