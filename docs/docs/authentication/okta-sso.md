---
layout: default
title: Okta
nav_order: 2
parent: Authentication
description: >
  This page contains instructions on setting up Okta
  as the SSO provider for Firezone.
---
---

Firezone supports Single Sign-On (SSO) through Okta.
After successfully configuring SSO with Firezone, users will be prompted to sign
in with their Okta credentials to in the Firezone portal to authenticate VPN
sessions, and download device configuration files.

![Firezone Okta SSO Login](){:width="600"}

To set up SSO, follow the steps below:

## Step 1 - Create Okta App Integration

_This section of the guide is based on
[Okta's documentation](https://help.okta.com/en/prod/Content/Topics/Apps/Apps_Apps.htm)._

In the Admin Console, go to `Applications > Applications` and click `Create App Integration`.
Set `Sign-in method` to `OICD - OpenID Connect` and `Application type` to `Web application`.

![Okta Create App Integration](https://user-images.githubusercontent.com/52545545/155907051-64a74d0b-bdcd-4a22-bfca-542dacc8ad20.png){:width="600"}

![Okta Create Options](https://user-images.githubusercontent.com/52545545/155909125-25d6ddd4-7d0b-4be4-8fbc-dc673bb1f61f.png){:width="600"}

On the following screen, configure the following settings:

1. **App Name**: `Firezone`
1. **App logo**:
[Firezone logo](https://user-images.githubusercontent.com/52545545/155907625-a4f6c8c2-3952-488d-b244-3c37400846cf.png)
(save link as).
1. **Sign-in redirect URIs**:The `auth/okta/callback` page on your Firezone
instance's fully qualified domain name.
In this example the domain is `https://firezone.example.com`),
**but yours will be different**.
1. **Sign-out redirect URIs**: Your firezone instance's fully qualified domain name.
1. **Assignments**:
Limit to the groups you wish to provide access to your Firezone instance.

![Okta Settings](https://user-images.githubusercontent.com/52545545/155907987-caa3318e-4871-488d-b1d4-deb397a17f19.png){:width="600"}

Once settings are saved, you will be given a Client ID and Client Secret.
These will be used in Step 2 to configure Firezone.

## Step 2 - Configure Firezone
