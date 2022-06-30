---
layout: default
title: Azure Active Directory
nav_order: 3
parent: Authenticate
description: >
  This page contains instructions on integrating Azure AD as
  an identity provider for Firezone
---

Firezone supports Single Sign-On (SSO) using Azure Active Directory through the generic
OIDC connector. This guide will walk you through how to obtain the following
config settings required for the integration:

1. `discovery_document_uri`: This URL returns a JSON with information to
construct a request to the OpenID server.
1. `client_id`: The client ID of the application.
1. `client_secret`: The client secret of the application.
1. `redirect_uri`: Instructs OIDC provider where to redirect after authentication.
This should be your Firezone `EXTERNAL_URL + /auth/oidc/<provider_key>/callback/`
(e.g. `https://firezone.example.com/auth/oidc/azure/callback/`).
1. `response_type`: Set to `code`.
1. `scope`: [OIDC scopes](https://openid.net/specs/openid-connect-basic-1_0.html#Scopes)
to obtain from your OIDC provider. This should be set to `openid email profile offline_access`
to provide Firezone with the user's email in the returned claims.
1. `label`: The button label text that shows up on your Firezone login screen.

![Azure SSO](https://user-images.githubusercontent.com/52545545/168922621-1f0f4dea-adfc-4e15-a140-a2f213676103.gif)

## Obtain Config Settings

_This guide is adapted from the [Azure Active Directory documentation](https://docs.microsoft.com/en-us/azure/active-directory/fundamentals/auth-oidc)._

Navigate to the Azure Active Directory page on the Azure portal.
Select the App registrations link under the Manage menu, click
`New Registration`, and register after entering the following:

1. `Name`: `Firezone`
1. `Supported account types`: `(Default Directory only - Single tenant)`
1. `Redirect URI`: This should be your firezone `EXTERNAL_URL + /auth/oidc/azure/callback/`
(e.g. `https://firezone.example.com/auth/oidc/azure/callback/`).
Make sure you include the trailing slash.
**This will be the `redirect_uri` value**.

![App Registration](https://user-images.githubusercontent.com/52545545/168722092-716c8448-4dc4-4d7a-a25c-1af701a57744.png)

After registering, open the details view of the application and copy the
`Application (client) ID`. **This will be the `client_id` value**. Next, open
the endpoints menu to retrieve the `OpenID Connect metadata document`.
**This will be the `discovery_document_uri` value**.

![Azure Client ID](https://user-images.githubusercontent.com/52545545/168724099-100e4a9a-0bf6-42f6-b0ee-13a4c9a8da23.png)

Next, select the Certificates & secrets link under the Manage menu and
create a new client secret. Copy the client secret - **this will be the
`client_secret` value**.

![Add a client secret](https://user-images.githubusercontent.com/52545545/168720697-1a28d2c1-4108-459c-9915-4397a4108818.png)

Lastly, select the API permissions link under the Manage menu,
click `Add a permission`, and select `Microsoft Graph`. Add `email`, `openid`,
`offline_access` and `profile` to the required permissions.

![Permissions](https://user-images.githubusercontent.com/52545545/171556138-26de489b-7de5-4b53-91dc-dc8058f0f901.png)

## Integrate With Firezone

Edit `/etc/firezone/firezone.rb` to include the options below.

```ruby
# Using Azure Active Directory as the SSO identity provider
default['firezone']['authentication']['oidc'] = {
  azure: {
    discovery_document_uri: "https://login.microsoftonline.com/<TENANT_ID>/v2.0/.well-known/openid-configuration",
    client_id: "<CLIENT_ID>",
    client_secret: "<CLIENT_SECRET>",
    redirect_uri: "https://firezone.example.com/auth/oidc/azure/callback",
    response_type: "code",
    scope: "openid email profile offline_access",
    label: "Azure"
  }
}
```

Run `firezone-ctl reconfigure`and `firezone-ctl restart` to update the application.
You should now see a `Sign in with Azure` button at the root Firezone URL.

## Restricting Access to Certain Members

Azure AD allows admins to restrict app access to a subset of users within your
organization. See Microsoft's
[documentation](https://docs.microsoft.com/en-us/azure/active-directory/develop/howto-restrict-your-app-to-a-set-of-users)
for more information on how to do this.
