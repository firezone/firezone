---
title: Regenerate Secret Keys
sidebar_position: 7
---

When you install Firezone, secrets are generated for encrypting database
fields, securing WireGuard tunnels, securing cookie sessions, and more.

If you're looking to regenerate one or more of these secrets, it's possible
to do so using the same bootstrap scripts that were used when installing
Firezone.

## Regenerate secrets

:::warning
Replacing the `DATABASE_ENCRYPTION_KEY` will render all encrypted data in the
database useless. This **will** break your Firezone install unless you are
starting with an empty database. You have been warned.
:::

:::caution
Replacing `GUARDIAN_SECRET_KEY`, `SECRET_KEY_BASE`, `LIVE_VIEW_SIGNING_SALT`,
`COOKIE_SIGNING_SALT`, and `COOKIE_ENCRYPTION_SALT` will reset all browser
sessions and REST API tokens.
:::

Use the procedure below to regenerate secrets:

<Tabs>
<TabItem value="docker" label="Docker" default>

Navigate to the Firezone installation directory, then:

```bash
mv .env .env.bak
docker run firezone/firezone bin/gen-env > .env
```

Now, move desired env vars from `.env.bak` back to `.env`, keeping
the new secrets intact.

</TabItem>
<TabItem value="omnibus" label="Omnibus">

```bash
mv /etc/firezone/secrets.json /etc/firezone/secrets.bak.json
sudo firezone-ctl reconfigure
```

</TabItem>
</Tabs>

## Regenerate WireGuard private key

:::warning
Replacing the WireGuard private key will render all existing device configs
invalid. Only do so if you're prepared to also regenerate device configs
after regenerating the WireGuard private key.
:::

To regenerate WireGuard private key, simply move or rename the private key file.
Firezone will generate a new one on next start.

<Tabs>
<TabItem value="docker" label="Docker" default>

```bash
cd $HOME/.firezone
docker-compose stop firezone
sudo mv firezone/private_key firezone/private_key.bak
docker-compose start firezone
```

</TabItem>
<TabItem value="omnibus" label="Omnibus">

```bash
sudo firezone-ctl stop phoenix
sudo mv /var/opt/firezone/cache/wg_private_key /var/opt/firezone/cache/wg_private_key.bak
sudo firezone-ctl start phoenix
```

</TabItem>
</Tabs>
