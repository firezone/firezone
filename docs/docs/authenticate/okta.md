---
title: Okta
sidebar_position: 2
---

Firezone supports Single Sign-On (SSO) using Okta
through the generic OIDC connector. This guide will walk you through how to
obtain the following config settings required for the integration:

1. `discovery_document_uri`: The
[OpenID Connect provider configuration URI](https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderConfig)
which returns a JSON document used to construct subsequent requests to this
OIDC provider.
1. `client_id`: The client ID of the application.
1. `client_secret`: The client secret of the application.
1. `redirect_uri`: Instructs OIDC provider where to redirect after authentication.
This should be your Firezone `EXTERNAL_URL + /auth/oidc/<provider_key>/callback/`
(e.g. `https://firezone.example.com/auth/oidc/okta/callback/`).
1. `response_type`: Set to `code`.
1. `scope`: [OIDC scopes](https://openid.net/specs/openid-connect-basic-1_0.html#Scopes)
to obtain from your OIDC provider. This should be set to `openid email profile offline_access`
to provide Firezone with the user's email in the returned claims.
1. `label`: The button label text that shows up on your Firezone login screen.

![Firezone Okta SSO Login](https://user-images.githubusercontent.com/52545545/156855886-5a4a0da7-065c-4ec1-af33-583dff4dbb72.gif)

## Step 1 - Create Okta App Integration

_This section of the guide is based on
[Okta's documentation](https://help.okta.com/en/prod/Content/Topics/Apps/Apps_App_Integration_Wizard_OIDC.htm)._

In the Admin Console, go to **Applications > Applications** and click
**Create App Integration**. Set **Sign-in method** to **OICD - OpenID Connect**
and **Application type** to **Web application**.

![Okta Create Options](https://user-images.githubusercontent.com/52545545/168918378-0dd9f705-2544-412d-bbbe-4a7cd9253907.png)

On the following screen, configure the following settings:

1. **App Name**: `Firezone`
1. **App logo**:
[Firezone logo](https://user-images.githubusercontent.com/52545545/155907625-a4f6c8c2-3952-488d-b244-3c37400846cf.png)
(save link as).
1. **Grant Type**: Check the **Refresh Token** box. This ensures Firezone syncs
with the identity provider and VPN access is terminated once the user is removed.
1. **Sign-in redirect URIs**: Add your Firezone `EXTERNAL_URL + /auth/oidc/okta/callback/`
(e.g. `https://firezone.example.com/auth/oidc/okta/callback/`) as an entry to
Authorized redirect URIs.
1. **Assignments**:
Limit to the groups you wish to provide access to your Firezone instance.

![Okta Settings](https://user-images.githubusercontent.com/52545545/172768478-e8be516d-aa0a-4882-b017-adc938bbd10b.png)

Once settings are saved, you will be given a **Client ID**, **Client Secret**,
and **Okta Domain**. These 3 values will be used in Step 2 to configure Firezone.

![Okta credentials](https://user-images.githubusercontent.com/52545545/172768856-8a373d56-1362-4fc3-a747-3c84f0e76dae.png)

## Integrate With Firezone

Edit `/etc/firezone/firezone.rb` to include the options below. Your `discovery_document_url`
will be `/.well-known/openid-configuration` appended to the end of your `okta_domain`.

```ruby
# Using Okta as the SSO identity provider
default['firezone']['authentication']['oidc'] = {
  okta: {
    discovery_document_uri: "https://<OKTA_DOMAIN>/.well-known/openid-configuration",
    client_id: "<CLIENT_ID>",
    client_secret: "<CLIENT_SECRET>",
    redirect_uri: "https://firezone.example.com/auth/oidc/okta/callback/",
    response_type: "code",
    scope: "openid email profile offline_access",
    label: "Okta"
  }
}
```

Run `firezone-ctl reconfigure`and `firezone-ctl restart` to update the application.
You should now see a **Sign in with Okta** button at the root Firezone URL.

## Restricting Access to Certain Users

Okta can limit the users with access to the Firezone app. To do this,
go to the Assignments tab of the Firezone App Integration in your Okta
Admin Console.

![Okta Assignments](https://user-images.githubusercontent.com/52545545/172766608-b95e20e2-eb58-4085-b532-84386de1ea23.png)
