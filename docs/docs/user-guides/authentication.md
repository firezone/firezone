---
layout: default
title: Authentication
nav_order: 4
parent: User Guides
description: >
  This page contains all the authentication methods that Firezone supports.
---
---

Firezone provides the ability to require authentication to establish VPN connections.

**Note**: To re-authenticate a VPN session, a user will need to turn off their
VPN connection and log in to the Firezone portal (URL specified during
[deployment]({%link docs/deploy/prerequisites.md%})
).

![re-authenticate](https://user-images.githubusercontent.com/52545545/155811459-bba6c4f5-ed85-4a35-bf95-ce6ff4fc2eb4.gif){:width="600"}

## Web Authentication (default)

Firezone will use the user's email address and password
to authenticate their VPN session.
You can set the session length to a minimum of 1 hour and maximum of 90 days.
Setting this to Never disables this setting, allowing VPN sessions indefinitely.
This is the default.

![Add Web Auth](https://user-images.githubusercontent.com/52545545/153466175-0e1c3ec8-aa3a-42a9-a915-748c9432a10c.png){:width="600"}

## Single Sign On (coming soon)

Single Sign-On is currently under development!
[Contact us](https://e04kusl9oz5.typeform.com/to/Ls4rbMSR#source=docs)
to share your requirements and be notified when it's available.
