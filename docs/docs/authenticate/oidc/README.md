---
title: OpenID Connect
sidebar_position: 10
---

Firezone supports Single Sign-On (SSO) via OpenID Connect (OIDC).

## Provider Support

In general, most IdPs that offer OIDC support work with Firezone. Some providers
that only implement the OIDC partially or use uncommon configurations may have
issues with Firezone.

OIDC providers known to work well with Firezone:

- [Azure Active Directory](oidc/azuread)
- [Google Workspace](oidc/google)
- [Okta](oidc/okta)
- [Onelogin](oidc/onelogin)

## General Instructions

If you're using an OIDC provider not listed above, the following OIDC attributes
are required for the setting up an OIDC provider
in Firezone:

1. `discovery_document_uri`: The
[OpenID Connect provider configuration URI](https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderConfig)
which returns a JSON document used to construct subsequent requests to this
OIDC provider. Some providers refer to this as the "well-known URL".
1. `client_id`: The client ID of the application.
1. `client_secret`: The client secret of the application.
1. `redirect_uri`: Instructs OIDC provider where to redirect after authentication.
This should be your Firezone `EXTERNAL_URL + /auth/oidc/<provider_key>/callback/`
(e.g. `https://firezone.example.com/auth/oidc/google/callback/`).
1. `response_type`: Set to `code`.
1. `scope`: [OIDC scopes](https://openid.net/specs/openid-connect-basic-1_0.html#Scopes)
to obtain from your OIDC provider. At a minimum, Firezone requires the `openid`
and `email` scopes.
1. `label`: The button label text displayed on the Firezone portal login page.
