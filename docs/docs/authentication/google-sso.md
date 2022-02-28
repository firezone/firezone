---
layout: default
title: Google
nav_order: 1
parent: Authentication
description: >
  This page contains instructions on setting up Google
  as the SSO provider for Firezone.
---
---

Firezone supports Single Sign-On (SSO) through Gmail / Google Workspace / GSuite.
After successfully configuring SSO with Firezone, users will be prompted to sign
in with their Google credentials to in the Firezone portal to authenticate VPN
sessions, and download device configuration files.

![Firezone Google SSO Login](){:width="600"}

To set up SSO, follow the steps below:

## Step 1 - Create OAuth Client IDs

_This section is based off Google's own documentation on
[setting up OAuth 2.0](https://support.google.com/cloud/answer/6158849)._

Visit the Google Cloud Console
[Credentials page](https://console.cloud.google.com/apis/credentials)
page, click `+ Create Credentials` and select `OAuth client ID`.

![Create OAuth Client ID](https://user-images.githubusercontent.com/52545545/155904211-c36095b9-4bbd-44c1-95f8-bb165e314af3.png){:width="600"}

On the OAuth client ID creation screen:

1. Set `Application Type` to `Web application`
1. Add an entry to `Authorized redirect URIs` with the
`auth/google/callback` page on your Firezone's fully qualified domain name.
In this example the domain is `https://firezone.example.com`),
**but yours will be different**. The redirect URI is where the service will redirect
the user after they authorize (or deny) the Firezone application.

![Create OAuth client ID](https://user-images.githubusercontent.com/52545545/155904581-9a82fc9f-26ce-4fdf-8143-060cbad0a207.png){:width="600"}

Note: if this is the first time you are creating a new OAuth client ID, you will
be asked to configure a consent screen. Configuring the consent screen is outside
the scope of this guide, see
[Google's documentation](https://support.google.com/cloud/answer/10311615)
for more information.

After creating the OAuth client ID, you will be given a Client ID and Client Secret.
These will be used in Step 2.
![Copy Client ID and Secret](https://user-images.githubusercontent.com/52545545/155906344-aa3673e1-903a-482f-86fb-75f12fd17f4f.png){:width="600"}

## Step 2 - Configure Firezone
