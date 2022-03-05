---
layout: default
title: Add Devices
nav_order: 2
parent: User Guides
description: >
  To add devices to Firezone, follow these commands.
---
---

**We recommend asking users to generate their own device configs so the private
key is only exposed to them.** Users can follow instructions on the
[Client Instructions]({%link docs/user-guides/client-instructions.md%})
page to generate their own device configs.

## Admin device config generation

Firezone admins can generate device configs for all users. This can be done by
clicking the "Add Device" button under `/devices` or `/users`.

![add device under devices](https://user-images.githubusercontent.com/52545545/153468000-06b2ea64-30b3-4f62-a2f4-043e5f231cb4.png){:width="600"}

![add device under user](https://user-images.githubusercontent.com/52545545/153467794-a9912bf0-2a13-4d05-9df9-2bd6e32b594c.png){:width="600"}

Once the device profile is created, you can send the WireGuard configuration
file to the user by:

* **Shareable Link**: Generates a time limited link to the device config file
that can be sent to the user.
* **Download Config**: Downloads the device config file to your local machine
to be sent securely to the user.

Devices are associated with users. See [Add Users
]({% link docs/user-guides/add-users.md %}) for more information on how to add
a user.

\
[Related: Client Instructions]({%link docs/user-guides/client-instructions.md%}){:.btn.btn-purple}
