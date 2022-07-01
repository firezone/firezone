---
layout: default
title: Authenticate
nav_order: 3
has_children: true
has_toc: false
description: >
  This page documents all the authentication methods that Firezone supports.
---

Firezone can be configured to require authentication before users can generate
or download device configuration files. Optionally,
[periodic re-authentication](#enforce-periodic-re-authentication)
can also be required for users to maintain their VPN session.

![Azure SSO](https://user-images.githubusercontent.com/52545545/168922621-1f0f4dea-adfc-4e15-a140-a2f213676103.gif)

By default, Firezone uses local email/password authentication, but can also
support integration with any generic OpenID Connect
(OIDC) identity provider. This allows users to sign in to Firezone using
their credentials from Okta, Google, Azure AD, or your own custom identity provider.

## Integrating A Generic OIDC Provider

The example below details the config settings required by Firezone to enable SSO
through an OIDC provider. The configuration file can be found at
`/etc/firezone/firezone.rb`. To pick up changes, run `firezone-ctl reconfigure`
and `firezone-ctl restart` to update the application.

```ruby
# This is an example using Google and Okta as an SSO identity provider.
# Multiple OIDC configs can be added to the same Firezone instance.

default['firezone']['authentication']['oidc'] = {
  google: {
    discovery_document_uri: "https://accounts.google.com/.well-known/openid-configuration",
    client_id: "<GOOGLE_CLIENT_ID>",
    client_secret: "<GOOGLE_CLIENT_SECRET>",
    redirect_uri: "https://firezone.example.com/auth/oidc/google/callback/",
    response_type: "code",
    scope: "openid email profile",
    label: "Google"
  },
  okta: {
    discovery_document_uri: "https://<OKTA_DOMAIN>/.well-known/openid-configuration",
    client_id: "<OKTA_CLIENT_ID>",
    client_secret: "<OKTA_CLIENT_SECRET>",
    redirect_uri: "https://firezone.example.com/auth/oidc/okta/callback/",
    response_type: "code",
    scope: "openid email profile offline_access",
    label: "Okta"
  }
}
```

1. `discovery_document_uri`: This URL returns a JSON with information to
construct a request to the OpenID server.
1. `client_id`: The client ID of the application.
1. `client_secret`: The client secret of the application.
1. `redirect_uri`: Instructs OIDC provider where to redirect after authentication.
This should be your Firezone `EXTERNAL_URL + /auth/oidc/<provider_key>/callback/`
(e.g. `https://firezone.example.com/auth/oidc/google/callback/`).
1. `response_type`: Set to `code`.
1. `scope`: [OIDC scopes](https://openid.net/specs/openid-connect-basic-1_0.html#Scopes)
to obtain from your OIDC provider. This should be set to `openid email profile`
or `openid email profile offline_access` depending on the provider.
1. `label`: The button label text that shows up on your Firezone login screen.

We've included instructions on how to set up Firezone with several popular
identity providers:

* [AzureAD](../authenticate/azuread)
* [Google](../authenticate/google)
* [Okta](../authenticate/okta.md)
* [Local email/password authentication (default)](../authenticate/web-auth)

If your identity provider is not listed above, but has a generic OIDC
connector, please consult their documentation to find instructions on obtaining
the config settings required.

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
[deployment](../deploy/prerequisites)
).

See detailed Client Instructions on how to re-authenticate your session
[here](../user-guides/client-instructions).
