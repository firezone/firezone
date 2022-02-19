---
layout: default
title: Client Instructions
nav_order: 5
parent: User Guides
description: >
  Install the WireGuard client and import the configuration
  file sent by the administrator to establish a connection.
---
---

_This is written for the end user who will be connecting
to the Firezone VPN server._

Follow this guide to establish a connection to the
VPN server through the WireGuard native client.

## Step 1 - Install the native WireGuard client

Firezone is compatible with the official WireGuard clients found here:

* [MacOS](https://itunes.apple.com/us/app/wireguard/id1451685025)
* [Windows](https://download.wireguard.com/windows-client/wireguard-installer.exe)
* [iOS](https://itunes.apple.com/us/app/wireguard/id1441195209)
* [Android](https://play.google.com/store/apps/details?id=com.wireguard.android)

For operating systems not listed above see the Official WireGuard site: [
https://www.wireguard.com/install/](https://www.wireguard.com/install/).

## Step 2 - Download the connection config file

This will end in `.conf` and be sent to you by the Firezone administrator.

## Step 3 - Add the config to the client

Open the WireGuard client and import the `.conf` file.
Turn on the VPN connection by toggling the `Activate` switch.

![Client Instructions]({{site.asset_urls.client_instructions}}){:width="600"}
