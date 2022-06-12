---
layout: default
title: Onelogin
nav_order: 4
parent: Authenticate
description: >
  This page contains instructions on setting up Onelogin
  as the SSO provider for Firezone.
---
---

Firezone supports Single Sign-On (SSO) using Onelogin
through the generic OIDC connector. This guide will walk you through how to
obtain the following config settings required for the integration:

1. `discovery_document_uri`: This URL returns a JSON with information to
construct a request to the OpenID server.
1. `client_id`: The client ID of the application.
1. `client_secret`: The client secret of the application.
1. `redirect_uri`: Instructs OIDC provider where to redirect after authentication.
This should be your Firezone `EXTERNAL_URL + /auth/oidc/<provider_key>/callback/`
(e.g. `https://firezone.example.com/auth/oidc/onelogin/callback/`).
1. `response_type`: Set to `code`.
1. `scope`: [OIDC scopes](https://openid.net/specs/openid-connect-basic-1_0.html#Scopes)
to obtain from your OIDC provider. This should be set to `openid email profile`
to provide Firezone with the user's email in the returned claims.
1. `label`: The button label text that shows up on your Firezone login screen.

## Obtain Config Settings

### Step 1 - Configure Custom Connector

Create a new OIDC connector by visiting **Appliances > Custom Connectors**.

1. **App name**: `Firezone`
1. **Icon**: [Firezone logo](https://user-images.githubusercontent.com/52545545/156854754-da66a9e1-33d5-47f5-877f-eff8b330ab2b.png)
or
[Firezone icon](https://user-images.githubusercontent.com/52545545/156854754-da66a9e1-33d5-47f5-877f-eff8b330ab2b.png)
(save link as).
1. **Sign on method**: select **OpenID Connect**
1. **Redirect URI**: Add your Firezone `<EXTERNAL_URL> + /auth/oidc/onelogin/callback/`
(e.g. `https://firezone.example.com/auth/oidc/onelogin/callback/`).

![Onelogin Configuration](https://user-images.githubusercontent.com/52545545/173190108-569e5cb5-e66b-4505-a4c5-fedd22872a04.png)

### Step 2 - Configure the OIDC Application

Next, click **Add App to Connector** to create an OIDC application. You will
find the values for the config settings required by Firezone
under the **SSO** sub-menu.

![Onelogin Config Parameters](https://user-images.githubusercontent.com/52545545/173190389-d8cf7382-b415-413f-b16c-4196ccee6726.png)

## Integrate With Firezone

Edit `/etc/firezone/firezone.rb` to include the options below.

```ruby
# Using Google as the SSO identity provider
default['firezone']['authentication']['oidc'] = {
  onelogin: {
    discovery_document_uri: "https://<ONELOGIN_URL>/oidc/2/.well-known/openid-configuration",
    client_id: "<CLIENT_ID>",
    client_secret: "<CLIENT_SECRET>",
    redirect_uri: "https://firezone.example.com/auth/oidc/onelogin/callback",
    response_type: "code",
    scope: "openid email profile",
    label: "Onelogin"
  }
}
```

Run `firezone-ctl reconfigure`and `firezone-ctl restart` to update the application.
You should now see a `Sign in with Onelogin` button at the root Firezone URL.
