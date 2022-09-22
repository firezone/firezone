---
title: Zitadel
sidebar_position: 7
---

Firezone supports Single Sign-On (SSO) using Zitadel
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

![Firezone Zitadel SSO Login](https://user-images.githubusercontent.com/42775578/190861910-2a16881d-1a04-4515-9ed4-d6768db9efc0.gif)

## Requirements
 - Setup your own Zitadel Cloud account: https://zitadel.cloud/
 - Create your first Zitadel instance the Zitadel Customerportal https://zitadel.cloud/admin/instances
 - Login to your Zitadel instance and create a project (i.e. "Internal")

More information about these steps: https://docs.zitadel.com/docs/guides/start/quickstart#try-out-zitadel-cloud

## Create Zitadel Application

In the Instance Console, go to **Projects** and select the project you want. Click
**New**.
![Start adding a new application in the project site](https://user-images.githubusercontent.com/42775578/190860229-66dc21e3-96f0-46d3-bcf1-3d6ea6b99db2.png)

Give the application a name (i.e. "Firezone") and select the application type **WEB**.
![Name the applicaiton and select type WEB](https://user-images.githubusercontent.com/42775578/190860326-cb6998a1-035a-4324-89f8-3c31fb2dfeea.png)

Select **CODE** for the authentication method.
![Select authentication method CODE](https://user-images.githubusercontent.com/42775578/190860399-28c134d6-bd45-4da3-a433-4ae0b1e4ffca.png)

Specify the redirect URI and post logout URI. The redirect URI will be of the form `EXTERNAL_URL + /auth/oidc/zitadel/callback/`. The post logout URI can just be the `EXTERNAL_URL`.
![Specify the redirect URI and post logout URI](https://user-images.githubusercontent.com/42775578/190860569-6eec899e-5753-40a6-8535-2e32a6a882a9.png)

Check all the overview of the configuration and clich on **Create**.
![Configuratin Overview](https://user-images.githubusercontent.com/42775578/190860669-f478d930-24a0-4854-8631-bc3b1025e3db.png)

Copy the **ClientId** and **ClientSecret** as it will be used for the firezone configuration.
![image](https://user-images.githubusercontent.com/42775578/190860714-c3f38cd9-1a25-4044-ae3b-dd172be3d878.png)

In the application **Configuration** click on **Refresh Token** and then on **Save**. The refresh token is optional for some features of firezone.
![Application Configuration](https://user-images.githubusercontent.com/42775578/190860810-9eb2cf47-d7f9-4c70-b562-fcd04c08e9e8.png)

In the application **Token Settings** select **User roles inside ID Token** and **User Info inside ID Token**. Save it with a click on **Save**.
![Application Token Settings](https://user-images.githubusercontent.com/42775578/190860899-caee8ed8-b43c-47fa-8519-868d37ce0eb5.png)

## Integrate With Firezone

Edit `/etc/firezone/firezone.rb` to include the options below. Your `discovery_document_url`
will be `/.well-known/openid-configuration` appended to the end of your zitadel instance domain. 
You can find this domain for example in the application under **Urls**.

```ruby
# Using Zitadel as the SSO identity provider
default['firezone']['authentication']['oidc'] = {
  zitadel: {
    discovery_document_uri: "https://<ZITADEL_INSTANCE_DOMAIN>/.well-known/openid-configuration",
    client_id: "<CLIENT_ID>",
    client_secret: "<CLIENT_SECRET>",
    redirect_uri: "https://vpn.example.com/auth/oidc/zitadel/callback/",
    response_type: "code",
    scope: "openid email profile offline_access",
    label: "Zitadel"
  }
}
```

Run `firezone-ctl reconfigure` to update the application.
You should now see a **Sign in with Zitadel** button at the root Firezone URL.
![Sign in with Zitadel](https://user-images.githubusercontent.com/42775578/190861571-6c7c7db2-13b1-4d46-b080-368a73855c6d.png)


## Restricting Access to only Users with Roles

Zitadel can limit the users with access to the Firezone app. To do this,
go to the project where your created your application in. In **General** you can find **Check authorization on Authentication** which allows only user to login, and thus use firezone, if they have assigned at least one role.
![Zitadel check authorization on authentication](https://user-images.githubusercontent.com/42775578/190861300-68dad91d-1859-4dc5-8beb-16858bda5880.png)
