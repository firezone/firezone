---
layout: default
title: Authenticate
nav_order: 3
has_children: true
has_toc: false
description: >
  This page documents all the authentication methods that Firezone supports.
---
---

Firezone can be configured to require authentication before users can generate
or download device configuration files. Optionally,
[periodic re-authentication](#enforce-periodic-re-authentication)
can also be required for users to maintain their VPN session.

By default, Firezone uses local email/password authentication, but can also
support integration with any generic OpenID Connect
(OIDC) identity provider. This allows users to sign in to Firezone using
their credentials from their existing account at an OIDC Identity Provider (IdP),
such as Okta, Google, Azure AD, or your own custom identity provider.

## Integrating with a Generic OIDC Identity Provider

The example below details the config settings required by Firezone.
Reminder, the configuration file can be found at `/etc/firezone/firezone.rb` and
generally requires running `firezone-ctl reconfigure` to pick up changes.

```ruby
# Multiple OIDC configs can be added to the same Firezone instance.
default['firezone']['authentication']['oidc'] = {
  google: [
    discovery_document_uri: "https://accounts.google.com/.well-known/openid-configuration",
    client_id: "CLIENT_ID",
    client_secret: "CLIENT_SECRET",
    redirect_uri: "https://firezone.example.com/auth/oidc/google/callback",
    response_type: "code",
    scope: "openid email profile",
    label: "Google"
  ]
}
```

We've included instructions on how to set up Firezone with several popular
identity providers below:

* [Azure AD]({%link docs/authenticate/azure-ad.md%})
* [Google]({%link docs/authenticate/google.md%})
* [Okta]({%link docs/authenticate/okta.md%})
* [Local email/password authentication (default)]({%link docs/authenticate/web-auth.md%})

If your identity provider is not listed above, but has a generic OIDC
connector, please consult their documentation to find instructions on obtaining
the config settings above.

Join our [Slack](https://www.firezone.dev/slack) to request additional help or
open a [Github Issue](https://github.com/firezone/firezone/issues) to request
additional documentation for your provider.

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
