---
layout: default
title: Google
nav_order: 1
parent: Authenticate
description: >
  This page contains instructions on setting up Google
  as the SSO provider for Firezone.
---
---

Firezone supports Single Sign-On (SSO) using Google Workspace and Cloud Identity
through the generic OIDC connector. This guide will walk you through how to
obtain the following config settings required for the integration:

1. `discovery_document_uri`: This URL returns a JSON with information to
construct a request to the OpenID server.
1. `client_id`: The client ID of the application.
1. `client_secret`: The client secret of the application.
1. `redirect_uri`: Instructs OIDC provider where the response to the
request should be sent.
1. `response_type`: Set to `code`.
1. `scope`: The permissions required by Firezone.
This should be set to `openid email profile`.
1. `label`: The button label text that shows up on your Firezone login screen.

![Firezone Google SSO Login](https://user-images.githubusercontent.com/52545545/156853456-1ab3f041-1002-4c79-a266-82acb5802890.gif){:width="600"}

_Note: Previously, Firezone used pre-configured Oauth2 providers. We've moved to
OIDC based authentication, which allows for any OpenID Connect provider
(Google, Okta, Dex) to be used for authentication._

_We strongly recommend transitioning your existing Google or Okta-based SSO
configuration to the generic OIDC-based configuration format described here.
We'll be removing the Google-specific and Okta-specific SSO functionality
in a future release._

To set up SSO, follow the steps below:

## Obtain Config Settings

### Step 1 - OAuth Config Screen

If this is the first time you are creating a new OAuth client ID, you will
be asked to configure a consent screen.

**IMPORTANT**: Select `Internal` for user type. This ensures only accounts
belonging to users in your Google Workspace Organization can create device configs.
DO NOT select `External` unless you want to enable anyone with a valid Google Account
to create device configs.

![OAuth Consent Internal](https://user-images.githubusercontent.com/52545545/156853731-1e4ad1d4-c761-4a28-84db-cd880e3c46a3.png){:width="800"}

On the App information screen:

1. **App name**: `Firezone`
1. **App logo**: [Firezone logo](https://user-images.githubusercontent.com/52545545/156854754-da66a9e1-33d5-47f5-877f-eff8b330ab2b.png)
(save link as).
1. **Application home page**: the URL of your Firezone instance.
1. **Authorized domains**: the top level domain of your Firezone instance.

![OAuth Consent App Info](https://user-images.githubusercontent.com/52545545/156853737-211ab7de-4c8f-4104-b3e8-5586c7a2ce6e.png){:width="800"}

On the next step add the following scopes:

![OAuth Consent Scopes](https://user-images.githubusercontent.com/52545545/168910904-57e86d71-b8ae-4b11-8b9c-bf8a19127065.png){:width="800"}

### Step 2 - Create OAuth Client IDs

_This section is based off Google's own documentation on
[setting up OAuth 2.0](https://support.google.com/cloud/answer/6158849)._

Visit the Google Cloud Console
[Credentials page](https://console.cloud.google.com/apis/credentials)
page, click `+ Create Credentials` and select `OAuth client ID`.

![Create OAuth Client ID](https://user-images.githubusercontent.com/52545545/155904211-c36095b9-4bbd-44c1-95f8-bb165e314af3.png){:width="800"}

On the OAuth client ID creation screen:

1. Set `Application Type` to `Web application`
1. Add an entry to Authorized redirect URIs that consists of appending
`/auth/oidc/google/callback/` to your Firezone base URL. For example, if your Firezone
instance is available at `https://firezone.example.com`, then you would enter
`https://firezone.example.com/auth/google/callback` here. The redirect URI is
where Google will redirect the user's browser after successful authentication.
Firezone will receive this callback, initiate the user's session, and redirect
the user's browser to the appropriate page depending on the user's role.

![Create OAuth client ID](https://user-images.githubusercontent.com/52545545/168910923-819300d3-b0c2-49a6-81ee-884dce471362.png){:width="800"}

After creating the OAuth client ID, you will be given a Client ID and Client Secret.
These will be used together with the redirect URI in the next step.

![Copy Client ID and Secret](https://user-images.githubusercontent.com/52545545/168913326-10e694d2-cda0-4ed3-b401-2406b36af7c0.png){:width="800"}

## Integrate With Firezone

Edit `/etc/firezone/firezone.rb` to include the options below.

```ruby
# Using Google as the SSO identity provider
default['firezone']['authentication']['oidc'] = {
  google: {
    discovery_document_uri: "https://accounts.google.com/.well-known/openid-configuration",
    client_id: "CLIENT_ID",
    client_secret: "CLIENT_SECRET",
    redirect_uri: "https://firezone.example.com/auth/oidc/google/callback",
    response_type: "code",
    scope: "openid email profile",
    label: "Google"
  }
}
```

Run `firezone-ctl reconfigure`and `firezone-ctl restart` to update the application.
You should now see a `Sign in with Google` button at the root Firezone URL.
