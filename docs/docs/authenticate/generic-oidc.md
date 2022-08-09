---
title: Generic OIDC Provider
sidebar_position: 10
---

The example below details the config settings required by Firezone to enable SSO
through a generic OIDC provider. The configuration file can be found at
`/etc/firezone/firezone.rb`. To pick up changes, run `firezone-ctl reconfigure`
to update the application.

```ruby
# This is an example using Google and Okta as an SSO identity provider.
# Multiple OIDC configs can be added to the same Firezone instance.

# Firezone can disable a user's VPN if there's any error detected trying
# to refresh their access_token. This is verified to work for Google, Okta, and
# Azure SSO and is used to automatically disconnect a user's VPN if they're removed
# from the OIDC provider. Leave this disabled if your OIDC provider
# has issues refreshing access tokens as it could unexpectedly interrupt a
# user's VPN session.
default['firezone']['authentication']['disable_vpn_on_oidc_error'] = false

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

The following config settings are required for the integration:

1. `discovery_document_uri`: The
[OpenID Connect provider configuration URI](https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderConfig)
which returns a JSON document used to construct subsequent requests to this
OIDC provider.
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
