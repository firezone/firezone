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

## Enforce Periodic Re-authentication

Periodic re-authentication can be enforced by changing the setting in
`settings/security`. This can be used to ensure a user must sign in to Firezone
periodically in order to maintain their VPN session.

![periodic-auth](https://user-images.githubusercontent.com/52545545/160450817-26406854-285c-4977-aa69-033eee2cfa57.png){:width="600"}

You can set the session length to a minimum of 1 hour and maximum of 90 days.
Setting this to Never disables this setting, allowing VPN sessions indefinitely.
This is the default.

To re-authenticate an expired VPN session, a user will need to turn off their
VPN session and sign in to the Firezone portal (URL specified during
[deployment]({%link docs/deploy/prerequisites.md%})
).

See detailed Client Instructions on how to re-authenticate your session
[here]({%link docs/user-guides/client-instructions.md%}).
