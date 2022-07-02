---
title: Running SQL Queries
sidebar_position: 7
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
* [Backing up the DB](#backing-up-the-db)

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

#### Backing up the DB

The `pg_dump` utility is also bundled; this can be used to take
consistent backups of the database. To dump a copy of the database in the
standard SQL query format execute it like this (replace `/path/to/backup.sql`
with the location to create the SQL file):

```shell
/opt/firezone/embedded/bin/pg_dump \
  -U firezone \
  -d firezone \
  -h localhost \
  -p 15432 > /path/to/backup.sql
```
