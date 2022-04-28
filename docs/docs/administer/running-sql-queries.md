---
layout: default
title: Running SQL Queries
nav_order: 7
parent: Administer
description: >
  Running SQL directly on the embedded Postgresql instance.
---
---

Firezone bundles a Postgresql server and matching `psql` utility that can be
used from the local shell like so:

```shell
/opt/firezone/embedded/bin/psql \
  -U firezone \
  -d firezone \
  -h localhost \
  -p 15432 \
  -c "SQL_STATEMENT"
```

This can be useful for debugging or troubleshooting purposes. It can also be
used to modify Firezone configuration data, but **this can have unintended
consequences**. We recommend using the UI (or upcoming API) <!-- XXX: Remove
"upcoming API" when API is implemented --> whenever possible.

Some examples of common tasks:

* [Listing all users](#listing-all-users)
* [Listing all devices](#listing-all-devices)
* [Changing a user's role](#changing-a-users-role)

#### Listing all users

```shell
/opt/firezone/embedded/bin/psql \
  -U firezone \
  -d firezone \
  -h localhost \
  -p 15432 \
  -c "SELECT * FROM users;"
```

#### Listing all devices

```shell
/opt/firezone/embedded/bin/psql \
  -U firezone \
  -d firezone \
  -h localhost \
  -p 15432 \
  -c "SELECT * FROM devices;"
```

#### Changing a user's role

Set role to `'admin'` or `'unprivileged'`:

```shell
/opt/firezone/embedded/bin/psql \
  -U firezone \
  -d firezone \
  -h localhost \
  -p 15432 \
  -c "UPDATE users SET role = 'admin' WHERE email = 'user@example.com';"
```
