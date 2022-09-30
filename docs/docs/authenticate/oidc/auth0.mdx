---
title: Auth0
sidebar_position: 7
---

Firezone supports Single Sign-On (SSO) using Auth0
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
(e.g. `https://firezone.example.com/auth/oidc/auth0/callback/`).
1. `response_type`: Set to `code`.
1. `scope`: [OIDC scopes](https://openid.net/specs/openid-connect-basic-1_0.html#Scopes)
to obtain from your OIDC provider. This should be set to `openid email profile`
to provide Firezone with the user's email in the returned claims.
1. `label`: The button label text that shows up on your Firezone login screen.

## Obtain Config Settings

### Step 1 - Create and set up an application

In the Auth0 dashboard, create an application.
Select **Regular Web Application** as the application type.

![Auth0 Configuration](https://user-images.githubusercontent.com/52545545/193337715-f8cb49e7-17b3-4c9c-bc75-9fdc51b66835.png)

Next, visit the settings tab on the application details page. Take note and
modify the following parameters:

1. **Name**: `Firezone`
1. **Domain**: The domain will be used to construct
the url to retreive the OIDC discovery document -
`https://<AUTH0_DOMAIN>/.well-known/openid-configuration`
1. **Icon**:
[Firezone icon](https://user-images.githubusercontent.com/52545545/156854754-da66a9e1-33d5-47f5-877f-eff8b330ab2b.png)
(save link as).
1. Set **Allowed Callback URLs** to `<EXTERNAL_URL> + /auth/oidc/auth0/callback/`
(e.g. `https://firezone.example.com/auth/oidc/auth0/callback/`).
This will be the `redirect_uri` in the Firezone config.

![Auth0 settings 1](https://user-images.githubusercontent.com/52545545/193341643-1aeb620a-85a6-4778-a425-2d092cf13bdc.png)
![Auth0 settings 2](https://user-images.githubusercontent.com/52545545/193341638-710de54a-b988-4f5e-8c18-78639695efac.png)
![Auth0 settings 3](https://user-images.githubusercontent.com/52545545/193341641-f94f0ecf-b16e-4831-af5b-5981d6634525.png)

## Integrate With Firezone

Visit the `/security` page in the Firezone portal.

Edit `/etc/firezone/firezone.rb` to include the options below.
Enter a JSON containing the config settings below to

```json
{
  "auth0": {
    "client_id": "<CLIENT_ID>",
    "client_secret": "<CLIENT_SECRET>",
    "discovery_document_uri": "https://<AUTH0_DOMAIN>/.well-known/openid-configuration",
    "label": "auth0",
    "redirect_uri": "https://<EXTERNAL_URL>/auth/oidc/auth0/callback/",
    "response_type": "code",
    "scope": "openid email profile"
  }
}
```

:::note
In past versions of Firezone (pre 0.6.0), adding an identity provider
for SSO required editing the main configuration file. As we have since moved to Docker
as the preferred deployment method, we recommend integrating
Auth0 and other identity providers in the Web GUI as described
in this guide.
:::

## Restricting Access to Certain Users

Auth0 supports setting access policies for which users
can access the Firezone application. See Auth0's
[Documentation](https://auth0.com/docs/manage-users/user-accounts/manage-user-access-to-applications)
for details.

## Automate Provision and Deprovisioning of Users

Firezone supports synchronizing with Auth0 to automatically
provisioning and de-provisioning user accounts.
If you are interested in this functionality, please
[contact us](https://www.firezone.dev/contact/sales)
for details.
