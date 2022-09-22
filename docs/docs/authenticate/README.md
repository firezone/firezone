---
title: Authenticate
sidebar_position: 3
---

Firezone can be configured to require authentication before users can generate
or download device configuration files. Optionally,
[periodic re-authentication](#enforce-periodic-re-authentication)
can also be required for users to maintain their VPN session.

Firezone supports the following authentication methods:

1. [Local email/password](../authenticate/local-auth): Enabled by default. A [time-based
one time password (TOTP)](../authenticate/multi-factor)
can optionally be configured to add an additional authentication factor.
1. [Single Sign-On (SSO)](#integrate-a-sso-provider): Enables users to sign
in using their credentials from Okta, Google, Azure AD, or any service supporting
the OpenID Connect (OIDC) protocol.

## Integrate A SSO Provider

We've included instructions on how to set up Firezone with several popular
identity providers:

* [Okta](../authenticate/okta)
* [Azure Active Directory](../authenticate/azuread)
* [Google](../authenticate/google)
* [Onelogin](../authenticate/onelogin)
* [Zitadel](../authenticate/zitadel)

If your identity provider is not listed above, but has a generic OIDC
connector, please consult their documentation to find instructions on obtaining
the config settings required. Instructions on setting up Firezone with a generic
OIDC provider can be found [here](../authenticate/generic-oidc).

Open a [Github Issue](https://github.com/firezone/firezone/issues)
to request documentation
or submit a [pull request](https://github.com/firezone/firezone/tree/master/docs/docs/authenticate/index.md)
to add documentation for your provider.
If you require assistance in setting up your OIDC provider, please
join the [Firezone Slack group](https://www.firezone.dev/slack).

### The OIDC Redirect URL

For each OIDC provider a corresponding URL is created for redirecting to
the configured provider's sign-in URL. The URL format is `https://firezone.example.com/auth/oidc/PROVIDER`
where `PROVIDER` is the OIDC key for that particular provider.

For example, the OIDC config below

```ruby
default['firezone']['authentication']['oidc'] = {
google: {
  # ...
},
okta: {
  # ...
}
```

would generate the following URLs:

* `https://firezone.example.com/auth/oidc/google`
* `https://firezone.example.com/auth/oidc/okta`

These URLs could then be distributed by an Admin directly to end users to navigate
to the appropriate identity provider login page to authenticate to Firezone.

## Enforce Periodic Re-authentication

Periodic re-authentication can be enforced by changing the setting in
`settings/security`. This can be used to ensure a user must sign in to Firezone
periodically in order to maintain their VPN session.

You can set the session length to a minimum of **1 hour** and maximum of **90 days**.
Setting this to Never disables this setting, allowing VPN sessions indefinitely.
This is the default.

### Re-authentication

To re-authenticate an expired VPN session, a user will need to turn off their
VPN session and sign in to the Firezone portal (URL specified during
[deployment](../deploy/prerequisites)
).

See detailed Client Instructions on how to re-authenticate your session
[here](../user-guides/client-instructions).

#### VPN Connection Status

A user's connection status is shown on the Users page under the table column
`VPN Connection`. The connection statuses are:

* ENABLED - The connection is enabled.
* DISABLED - The connection is disabled by an administrator or OIDC refresh failure.
* EXPIRED - The connection is disabled due to authentication expiration or a user
has not signed in for the first time.
