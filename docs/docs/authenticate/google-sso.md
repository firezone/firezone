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

Firezone supports Single Sign-On (SSO) through Google Workspace.
After successfully configuring SSO with Firezone, users will be prompted to sign
in with their Google credentials to in the Firezone portal to authenticate VPN
sessions, and download device configuration files.

![Firezone Google SSO Login](https://user-images.githubusercontent.com/52545545/156853456-1ab3f041-1002-4c79-a266-82acb5802890.gif){:width="600"}

To set up SSO, follow the steps below:

## Step 1 - Configure OAuth Consent Screen

If this is the first time you are creating a new OAuth client ID, you will
be asked to configure a consent screen.

Select `Internal` for user type. This ensures only accounts belonging to users
in your Google Workspace Organization can create device configs.

![OAuth Consent Internal](https://user-images.githubusercontent.com/52545545/156853731-1e4ad1d4-c761-4a28-84db-cd880e3c46a3.png){:width="800"}

On the App information screen:

1. **App name**: `Firezone`
1. **App logo**: [Firezone logo](https://user-images.githubusercontent.com/52545545/156854754-da66a9e1-33d5-47f5-877f-eff8b330ab2b.png)
(save link as).
1. **Application home page**: the URL of your Firezone instance.
1. **Authorized domains**: the top level domain of your Firezone instance.

![OAuth Consent App Info](https://user-images.githubusercontent.com/52545545/156853737-211ab7de-4c8f-4104-b3e8-5586c7a2ce6e.png){:width="800"}

On the next step add the `.../auth/userinfo.email` scope.

![OAuth Consent Scopes](https://user-images.githubusercontent.com/52545545/156853748-aed49198-989d-4b48-9e9a-108142bb4f8b.png){:width="800"}

## Step 2 - Create OAuth Client IDs

_This section is based off Google's own documentation on
[setting up OAuth 2.0](https://support.google.com/cloud/answer/6158849)._

Visit the Google Cloud Console
[Credentials page](https://console.cloud.google.com/apis/credentials)
page, click `+ Create Credentials` and select `OAuth client ID`.

![Create OAuth Client ID](https://user-images.githubusercontent.com/52545545/155904211-c36095b9-4bbd-44c1-95f8-bb165e314af3.png){:width="800"}

On the OAuth client ID creation screen:

1. Set `Application Type` to `Web application`
1. Add an entry to Authorized redirect URIs that consists of appending
`/auth/google/callback` to your Firezone base URL. For example, if your Firezone
instance is available at `https://firezone.example.com`, then you would enter
`https://firezone.example.com/auth/google/callback` here. The redirect URI is
where Google will redirect the user's browser after successful authentication.
Firezone will receive this callback, initiate the user's session, and redirect
the user's browser to the appropriate page depending on the user's role.

![Create OAuth client ID](https://user-images.githubusercontent.com/52545545/155904581-9a82fc9f-26ce-4fdf-8143-060cbad0a207.png){:width="800"}

After creating the OAuth client ID, you will be given a Client ID and Client Secret.
These will be used in Step 2.
![Copy Client ID and Secret](https://user-images.githubusercontent.com/52545545/155906344-aa3673e1-903a-482f-86fb-75f12fd17f4f.png){:width="800"}

## Step 3 - Configure Firezone

Edit the configuration located at `/etc/firezone/firezone.rb` to include the
following:

```ruby
# set the following variables to the values obtained in step 2
default['firezone']['authentication']['google']['enabled'] = true
default['firezone']['authentication']['google']['client_id'] = '<client_id>'
default['firezone']['authentication']['google']['client_secret'] = '<client_secret>'
default['firezone']['authentication']['google']['redirect_uri'] = 'https://firezone.example.com/auth/google/callback'
```

Run `firezone-ctl reconfigure` and `firezone-ctl restart` to apply the changes.
