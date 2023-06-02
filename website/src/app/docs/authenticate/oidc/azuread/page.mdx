---
title: Azure Active Directory
sidebar_position: 2
description: Enforce 2FA/MFA for users of Firezone's WireGuard®-based
  secure access platform. This guide walks through integrating Azure AD
  for single sign-on using OpenID Connect (OIDC).
---

# Enable SSO with Azure Active Directory (OIDC)

Firezone supports Single Sign-On (SSO) using Azure Active Directory through the generic
generic OIDC connector. This guide will walk you through how to obtain the following
config settings required for the integration:

1. **Config ID**: The provider's config ID. (e.g. `azure`)
1. **Label**: The button label text that shows up on your Firezone login screen. (e.g. `Azure`)
1. **Scope**: [OIDC scopes](https://openid.net/specs/openid-connect-basic-1_0.html#Scopes)
   to obtain from your OIDC provider. This should be set to `openid email profile offline_access`
   to provide Firezone with the user's email in the returned claims.
1. **Response type**: Set to `code`.
1. **Client ID**: The client ID of the application.
1. **Client secret**: The client secret of the application.
1. **Discovery Document URI**: The
   [OpenID Connect provider configuration URI](https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderConfig)
   which returns a JSON document used to construct subsequent requests to this
   OIDC provider.

![Azure SSO](https://user-images.githubusercontent.com/52545545/168922621-1f0f4dea-adfc-4e15-a140-a2f213676103.gif)

## Step 1: Obtain configuration parameters

_This guide is adapted from the [Azure Active Directory documentation](https://docs.microsoft.com/en-us/azure/active-directory/fundamentals/auth-oidc)._

Navigate to the Azure Active Directory page on the Azure portal.
Select the App registrations link under the Manage menu, click
`New Registration`, and register after entering the following:

1. **Name**: `Firezone`
1. **Supported account types**: `(Default Directory only - Single tenant)`
1. **Redirect URI**: This should be your Firezone `EXTERNAL_URL + /auth/oidc/<Config ID>/callback/`
   (e.g. `https://firezone.example.com/auth/oidc/azure/callback/`). **Make sure you include the trailing slash both
   when saving the provider in Firezone and in Azure AD (`redirect_uri` field on the screenshot below).**

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

## Step 2: Integrate with Firezone

Navigate to the `/settings/security` page in the admin portal, click
"Add OpenID Connect Provider" and enter the details you obtained in the steps
above.

Enable or disable the **Auto create users** option to automatically create
an unprivileged user when signing in via this authentication mechanism.

And that's it! The configuration should be updated immediately.
You should now see a `Sign in with Azure` button on the sign in page.

## Step 3 (optional): Restrict access to specific users

Azure AD allows admins to restrict OAuth application access to a subset of users
within your organization. See Microsoft's
[documentation](https://docs.microsoft.com/en-us/azure/active-directory/develop/howto-restrict-your-app-to-a-set-of-users)
for more information on how to do this.
