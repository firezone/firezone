---
layout: default
title: Client Instructions
nav_order: 5
parent: User Guides
description: >
  Install the WireGuard client and import the configuration
  file sent by the administrator to establish a VPN session.
---

## Table of contents

{: .no_toc}

1. TOC
{:toc}

---

_This is written for the end user who will be connecting
to the Firezone VPN server._

## Install and Setup

Follow this guide to establish a VPN session
through the WireGuard native client.

### Step 1 - Install the native WireGuard client

Firezone is compatible with the official WireGuard clients found here:

* [MacOS](https://itunes.apple.com/us/app/wireguard/id1451685025)
* [Windows](https://download.wireguard.com/windows-client/wireguard-installer.exe)
* [iOS](https://itunes.apple.com/us/app/wireguard/id1441195209)
* [Android](https://play.google.com/store/apps/details?id=com.wireguard.android)

For operating systems not listed above see the Official WireGuard site: [
https://www.wireguard.com/install/](https://www.wireguard.com/install/).

### Step 2 - Download the device config file

The device config file can either be obtained from your Firezone administrator
or self-generated via the Firezone portal.

To self generate a device config file, visit the domain provided by your Firezone
administrator. This URL will be specific to your company
(in this example it is `https://firezone.example.com`)

![Firezone Okta SSO Login](https://user-images.githubusercontent.com/52545545/156855886-5a4a0da7-065c-4ec1-af33-583dff4dbb72.gif){:width="600"}

### Step 3 - Add the config to the client

Open the WireGuard client and import the `.conf` file.
Activate the VPN session by toggling the `Activate` switch.

![Activate Tunnel](https://user-images.githubusercontent.com/52545545/156859686-41755bf7-a9ad-42ec-af5e-9f0734d962db.gif)

## Re-authenticating your session

If your network admin has required periodic authentication to maintain your VPN session,
follow the steps below. You will need:

* **URL of the Firezone portal**: Ask your Network Admin for the link.
* **Credentials**: Your username and password should be provided by your Network
Admin. If your company is using a Single Sign On provider (like Google or Okta),
the Firezone portal will prompt you to authenticate via that provider.

### Step 1 - Deactivate VPN session

![WireGuard Deactivate](https://user-images.githubusercontent.com/52545545/156859259-a3d386ce-b304-4caa-96e6-a8e7ca96d098.png)

### Step 2 - Re-authenticate

Visit the URL of your Firezone portal and log in using credentials provided by your
network admin.

![re-authenticate](https://user-images.githubusercontent.com/52545545/155812962-9b8688c1-00af-41e4-96c3-8fb52f840aed.gif){:width="600"}

### Step 3 - Activate VPN session

![Activate Session](https://user-images.githubusercontent.com/52545545/156859636-fde95fc5-5b9c-4697-9108-2f277ed3fbef.png)
