# Firezone Elixir Development

Before reading this doc, make sure you've read through our [CONTRIBUTING](../docs/CONTRIBUTING.md) guide.

## Getting Started

This is not an in depth guide for setting up all dependencies, but it should give you a starting point.

Prerequisites:

- All prerequisites in the [CONTRIBUTING](../docs/CONTRIBUTING.md) guide
- Install ASDF and all plugins/tools from `.tool-version` in the top level of the Firezone repo
- Install [pnpm](https://pnpm.io/)

From the top level director of the Firezone repo start the Postgres container:

```
docker compose up -d postgres
```

Inside the `/elixir` directory run the following commands:

```
# Install dependencies
# --------------------
> mix deps.get

# Generate dev cert, install npm packages and build assets
# ---------------------------------------------------------
> mix phx.gen.cert
> mix setup

# Setup and seed the DB
# ---------------------
> mix ecto.seed

# Start the portal:
# ------------------
> iex -S mix
```

The web and API endpoints should now be running:

- Web -> https://localhost:13443/
- API -> ws://localhost:13001/

### Device trust certificate for local macOS testing

The local `firezone` seed account includes a synthetic device trust anchor CA:
`CN=Firezone Device Trust Test CA`. The matching test leaf certificate lives in
`test/support/fixtures/device_trust_challenges/leaf.pem`, with its private key
in `test/support/fixtures/device_trust_challenges/leaf.key`.

That leaf cert has:

- Subject CN: `dev.firezone.device-trust`
- Client Auth EKU
- SAN URI: `deviceid:test-device-id`
- Issuer CN: `Firezone Device Trust Test CA`

For Keychain Access testing, trust the synthetic CA and import the leaf cert and
private key together as a PKCS#12 identity. From the `elixir/` directory:

```sh
sudo security delete-identity \
  -Z BAA8CB681382BA068285D3354779D03587DFA389A31E61DC6F7F9D11CFD3014E \
  /Library/Keychains/System.keychain

sudo security delete-certificate \
  -Z BAA8CB681382BA068285D3354779D03587DFA389A31E61DC6F7F9D11CFD3014E \
  /Library/Keychains/System.keychain

sudo security add-trusted-cert \
  -d \
  -r trustRoot \
  -k /Library/Keychains/System.keychain \
  test/support/fixtures/device_trust_challenges/ca.pem

openssl pkcs12 -export \
  -keypbe PBE-SHA1-3DES \
  -certpbe PBE-SHA1-3DES \
  -macalg sha1 \
  -inkey test/support/fixtures/device_trust_challenges/leaf.key \
  -in test/support/fixtures/device_trust_challenges/leaf.pem \
  -certfile test/support/fixtures/device_trust_challenges/ca.pem \
  -name "dev.firezone.device-trust" \
  -out /tmp/firezone-device-trust-test.p12 \
  -passout pass:firezone

sudo security import /tmp/firezone-device-trust-test.p12 \
  -k /Library/Keychains/System.keychain \
  -t agg \
  -f pkcs12 \
  -A \
  -P firezone
```

The delete commands remove only the checked-in fixture identity by its stable
SHA-256 fingerprint. Do not delete by common name when testing alongside a real
MDM-issued cert, because both identities may use `dev.firezone.device-trust`.

The `-A` flag is for this local fixture import only. It applies to the private
key at import time and mirrors an MDM/SCEP profile that allows apps to use the
private key without prompting. If the identity was previously imported without
`-A`, `security delete-certificate` alone is not enough because the old private
key ACL can remain; delete the identity first, then reimport.

You can verify the cert and identity are present with:

```sh
security find-certificate -c dev.firezone.device-trust -a -Z /Library/Keychains/System.keychain
security find-identity -v /Library/Keychains/System.keychain
```

The identity command should include `dev.firezone.device-trust`. The macOS CA
trust above is only for local Keychain checks; Portal still validates the leaf
certificate against the seeded device trust anchor CA.

Do not use this fixture outside local development. The private key is checked in
only so the Network Extension can exercise the device trust signing path against
the seeded local CA.

### Stripe integration for local development

Prerequisites:

- Stripe account
- Stripe CLI

Steps:

- Reset and seed the database (seeds use static IDs that correspond to staging setup on Stripe):

  ```
  mix do ecto.reset, ecto.seed
  ```

- Start Stripe CLI webhook proxy:

  ```
  stripe listen --forward-to localhost:13001/integrations/stripe/webhooks
  ```

- Start the Phoenix server with enabled billing from the elixir/ folder using a test mode token:
  ```
  cd elixir/
  BILLING_ENABLED=true STRIPE_SECRET_KEY="...copy from stripe dashboard..." STRIPE_WEBHOOK_SIGNING_SECRET="...copy from stripe cli tool.." mix phx.server
  ```

When updating the billing plan in stripe, use the Stripe Testing Docs for how to add test payment info
