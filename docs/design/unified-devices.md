# Unified devices: merging the Client and Gateway roles

Status: draft plan, no code yet. Revised 2026-10-22 against `main` at 698b4b457.

How to read this: section 1 is the current split, section 2 the target model
(2.1 data, 2.2 control plane, 2.3 data plane, 2.4 Linux binaries, 2.5 admin
UI, 2.6 site-to-site, 2.7 wire compatibility rules), section 3 the PR-sized steps, 3a the deploy and release
order, 4 the decisions already
taken, 5 risks. If you only have ten minutes, read "Settled so far", 2.1, 3a
and 4.

Settled so far:

- One connlib instance per machine. Two instances on one host under different
  actors is not a supported configuration.
- A device row is the machine, not (machine x user). Users are recorded against
  the device, not duplicated into it.
- Tokens stay the universal credential. The per-account CA, keystore enrollment
  and TPM work are parked; the existing MDM-certificate attestation is unchanged.

## 1. Where we are

The `devices` table is already unified (PR #12687), but every layer above and
below it is still split by role:

| Layer              | Client                                                                                    | Gateway                                                                |
| ------------------ | ----------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| DB row             | `type = client`, `actor_id` required, `site_id` forbidden                                 | `type = gateway`, `site_id` required, `actor_id` forbidden             |
| Identity           | `(account, actor, firezone_id)` or `(account, cert issuer, serial, actor)`                | `(account, site, firezone_id)` or the single-owner token               |
| Credential         | `client_tokens` or X.509                                                                  | `gateway_tokens` (site-bound or device-bound, rotation, no expiry)     |
| Subject            | Always has an actor                                                                       | None. Gateway-side queries are `Safe.unscoped`                         |
| Socket             | `/client/v3`, last-wins, socket id = credential id                                        | `/gateway/v2`, first-wins, socket id = token id                        |
| Init payload       | resources, DNS, relays, inbound c2c authorizations                                        | no resources, relays expiring 2038, masquerade config (ignored)        |
| Receiver protocol  | `client_device_access_authorized`, auto-acked                                             | `create_authorization` with a signed `ref` echoed back                 |
| Receiver selection | pool criteria, `find_by_ipv4/6` (clients only)                                            | `site_id` match + geo/version balancing (gateways only)                |
| Policy evaluation  | initiator only, clauses match `type: :client`                                             | never                                                                  |
| Rust state         | `ClientState`, inbound via `ClientOnClient`                                               | `GatewayState`, inbound via `ClientOnGateway`                          |
| Linux binary       | `firezone-headless-client`; GUI deb ships `firezone-client-tunnel` and the `firezone` CLI | `firezone-gateway` deb with init script, deprecated `firezone` wrapper |
| Billing            | seats count actors with a `type = client` device seen this month                          | not counted                                                            |

Three facts that shape the plan:

- **Both token kinds share one secret scheme**, `sha3(nonce <> fragment <>
salt)` with an empty nonce for admin-issued tokens. Only the signing salt on
  the wire differs, and the socket endpoint picks it. Gateway token rows can be
  copied into the client token table with ids intact and every deployed
  `FIREZONE_TOKEN` keeps verifying.
- **"Separate Internet gateways" is a classification-order bug.** With the
  Internet resource authorized, the gateway skips its CIDR table and rejects
  every private range (`client_on_gateway.rs:563-577`). Longest-match first,
  Internet catch-all last, and one device can serve Internet plus LAN through
  an explicit CIDR resource.

## 2. Target model

### 2.1 Entities

```
Actor ──< DeviceActor >── Device ──< SiteDevice >── Site ──< Resource
  │                         │                                       │
  └──< Membership >── Group ┴─────────── Policy ────────────────────┘
                              (device pool resources hold their own
                               member criteria instead of a site)
```

**Device** is the machine, keyed by `firezone_id` or, for MDM-attested
devices, by certificate issuer and serial, in both cases without an actor in
the key.

| Column                                                                  | Change                                                     |
| ----------------------------------------------------------------------- | ---------------------------------------------------------- |
| `type`, `site_id`, `actor_id`                                           | removed                                                    |
| `client_token_id`, `gateway_token_id`                                   | collapsed into `token_id`, the token of the latest session |
| identity, trust, posture, verification, addresses, keys, latest-session | stay, once per machine                                     |

**DeviceActor** `(account, device, actor, first_seen_at, last_seen_at)`.
Created on connect when a user credential is presented. Feeds own-devices pool
criteria for offline devices, seats, the Devices page, and actor-deletion
cleanup.

**Session** is live only: device, the token's actor, public key,
capabilities. Policy evaluation reads the session's actor, as today.

**Actor** gains `managed_by: account | system`. Each account gets one system
service account ("Infrastructure") whose tokens the deploy flow mints by
default. It takes no seat, is not in `Everyone`, cannot sign in, and is
exempt from `connected_devices_per_actor`.

**Token** (today `client_tokens`) absorbs the two gateway token kinds:

| Column                  | Meaning                                                                                                                                                                                                                                             |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `device_id` (nullable)  | device-bound token, minted by the deploy flow for a pre-created device. Replaces single-owner gateway tokens and gives headless clients the same pre-provisioned deploy path.                                                                       |
| `rotated_at` (nullable) | rotation grace, as gateway tokens today                                                                                                                                                                                                             |
| `site_id` (nullable)    | auto-join site for a device created on first connect with this token. Replaces multi-owner site tokens, which most gateways still use. Creation stays closed, as the API sunset already says; verification, listing and revocation are first class. |

`expires_at` becomes nullable. Every token belongs to an actor, so every
session has a Subject. `gateway_tokens` is dropped after its rows are copied.

**Site** is a named set of devices that serve resources. Rows unchanged.
Assignment is `site_devices(account, site, device)`, explicit rows only.
Rule-based assignment reusing `DeviceMembershipCriteria` is possible later
without schema changes and is not planned. A device may be in any number of
sites and serves the union of their resources. The system-managed Internet Site goes
away in the last phase; the Internet resource is then assigned to a site like
any other.

**Resource** unchanged. `site_id` means "served by". Device pools keep their
own criteria.

**Policy** unchanged. Receiver selection sits behind
`Routing.select_receiver(resource, candidates, initiator)` as the hook for a
future routing strategy on the policy. A device is never selected to serve
its own request, and a resource served by a site the device is assigned to
is left out of that device's outbound view, since the network behind it is
local.

**Capabilities** reported at connect and kept in presence meta:
`{route_resources, route_internet, dns_recursion, iceless}`. Legacy gateway
binaries default to full routing; legacy clients to self-only.

### 2.2 Control plane

One channel core, `PortalAPI.Device.Channel.Core`, with thin protocol
adapters: `/gateway` v1 and v2 and `/client` v1 to v3 for deployed binaries,
and `/device/v1`, the union of both message sets on one socket. An adapter may
only rename messages, pick the view that renders payloads for its version, and
choose the ack mode; everything else lives in the core. Init carries the
outbound view, `resources` the device may reach, and the inbound view:
`sites_served`, `local_resources` (every resource served by those sites, the
list a gateway never had), and `authorizations` where the device is the
receiver. `local_resource_created_or_updated` and `local_resource_deleted`
keep the list current. Every device gets it, whether or not it serves
anything today. `create_authorization` gains `ice_role` and a
`target` of `self {pool_id, filters}` or a resource. The gateway-style ack
(device echoes the signed `ref` after installing the authorization) is the only
receiver protocol; the c2c auto-ack survives only in the `/client/v3` adapter.
Duplicate connects are last-wins on `/device/v1`; legacy gateway adapters
keep first-wins (see 2.7).

### 2.7 Wire compatibility rules

The message shapes on the legacy sockets never change. What can change is
the situation the portal puts a legacy binary in, and old code has no way to
refuse. These gates hold for every step that touches selection, assignment
or registration, and the legacy adapters enforce them:

- Co-hosting the Internet resource with other resources is allowed on any
  gateway and warned about, not gated. The warning, shown when an admin
  creates the combination (2.12b): users with access to the Internet
  resource can reach any non-private address the site's devices can reach,
  and gateways below 1.6.5 do not route the site's other resources while
  serving the Internet resource. The private-range reject list is the
  enforced boundary on legacy gateways; the unified binary also refuses
  Internet traffic into any resource it serves (5.6).
- A legacy gateway never receives a device pool target. Its resource parser
  has no such variant.
- A legacy gateway is never sent `disconnect` for being superseded. Deployed
  gateways treat every `disconnect` as an expired token, exit with code 78,
  and systemd does not restart them. The `/gateway` v1 and v2 adapters keep
  first-wins; only `/device/v1` is last-wins, with a distinct reason.
- A legacy client still gets a resource that changes sites as delete plus
  create, as today.
- Any new field in a legacy payload is additive and optional. Nothing is
  removed or renamed on a legacy socket.

### 2.3 Data plane

One `DeviceState` in `tunnel-proto`. Outbound half is today's `ClientState`.
Inbound half is one per-peer policy, `PeerInbound`, authorized for a set of
targets: `Self {pool, filters}` and `Resource {Cidr | Dns(nat) | Internet}`.
Classification: my TUN IP and pool-authorized, else longest-match routing
table, else Internet with the private-range reject list, else deny.
Tunnel-range destinations other than self stay denied, so a routing device
never hairpins two peers. Node keyed by `DeviceId`; ICE role and presets per
connection from the portal. A routing device answers site-scoped recursion on
`tun_ip:53535` and resolves DNS resources for peers through the bypass
resolvers, never through the sentinels its own OS resolver points at.
**Forwarding.** Served traffic leaves the daemon through one of two
forwarders behind one trait, chosen at run time; no flag selects a role.

- _Kernel forwarder_ (Linux only). The daemon translates the packet and
  writes it to the TUN device, as the gateway does today. The daemon owns
  the host setup instead of the admin: when the first resource to serve
  arrives it sets the forwarding sysctls and creates an nftables table of
  its own, `firezone`, holding the two masquerade rules scoped to the tunnel
  interface and prefixes. The table is deleted and recreated whenever
  serving starts and deleted when it stops or the daemon exits, so a crash
  leaves at most a stale table that the next start replaces. The sysctl
  value found is recorded and put back on shutdown if the daemon changed
  it; a value the admin set is left alone both ways. Nothing is touched before there is something to serve,
  so a laptop that only reaches resources is never turned into a router.
  The rules go away when the device stops serving, not at the next
  restart. `--no-kernel-forwarding` (and `FIREZONE_NO_KERNEL_FORWARDING`)
  skips this forwarder; a container without `NET_ADMIN` falls through to
  the next one instead of failing. The packaged daemon runs as the
  `firezone` user and cannot write the sysctls or take the iptables lock;
  there the kernel forwarder applies when the admin has turned forwarding
  on (0.8), whose rules it then assumes, and the device serves in userspace
  otherwise.
- _Userspace forwarder_ (every platform; the Linux fallback). TCP is
  terminated by smoltcp through `l3-tcp`, as the TCP DNS server already
  does, and each connection is paired with a host socket to the real
  resource address; UDP is a per-flow host socket keyed like a NAT entry.
  The resource sees the host's own address, as masquerade produces today,
  so policies and flow logs do not change. Served networks are already out
  of the device's own tunnel routes, so the host sockets leave by the LAN.
  ICMP echo is forwarded through the unprivileged ping APIs every platform
  has (the IP Helper ICMP functions on Windows, datagram ICMP sockets on
  macOS, iOS and Android, ping sockets on Linux): a table keyed by peer and
  echo identifier, the request re-sent with the same payload, the reply
  rebuilt with the original identifier, sequence and payload, entries
  expiring after a few seconds. Errors map from the host sockets: a refused
  TCP connect is a reset from the smoltcp socket, UDP port unreachable
  becomes an ICMP destination unreachable to the peer, timeouts stay
  timeouts. ICMP traceroute works through the same echo API where it
  reports time exceeded; UDP traceroute is best effort.

Windows serves through the userspace forwarder only: there is no NAT the
daemon can own on Windows (WinNAT allows one instance per host, conflicts
with Hyper-V, WSL and Docker Desktop, and has no IPv6). Pings to the
device's own tunnel address need neither forwarder; the host stack answers
them. The capability report names the forwarder that came up, `kernel` or
`userspace`, or reports that the device cannot route, so the portal and
support can tell the paths apart. The gateway init script survives as docs
for admins who manage forwarding and NAT themselves.

### 2.4 Linux binaries: two, `firezone` and the GUI

Today Linux has four daemons or CLIs across three packages, and two of them
already fight over `/usr/bin/firezone`: the gateway deb ships a deprecated
wrapper there and the GUI deb ships the IPC CLI there. The Linux tunnel service
is a bin of the Tauri package, so building it compiles Tauri.

Target:

| Binary                | Package                                                                     | Contents                                                                                           |
| --------------------- | --------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `firezone`            | `firezone` (deb, rpm, apt and rpm repos, docker image, tarball)             | daemon plus CLI in one executable                                                                  |
| `firezone-gui-client` | `firezone-gui-client` (deb, rpm), self-contained, conflicts with `firezone` | the same daemon and CLI plus the Tauri GUI, which talks to the daemon over the existing IPC socket |

`firezone` subcommands:

- `run`: the daemon. `ExecStart` of `firezone.service`. Serves the IPC socket,
  runs connlib. Behaviour comes from the credential and the init payload, not
  from flags: a device with served sites routes, a device with a user session
  reaches resources, a device with both does both.
- `authenticate`: stores a token at mode 0400, as `firezone-gateway
authenticate` does today. Also the path for headless service-account tokens.
- `sign-in`, `sign-out`: user credential on top, browser flow as the headless
  client does today, deep link when the GUI is present.
- `status`, `resources`, `internet-resource`, `connect`, `disconnect`: the
  current `firezone` CLI over IPC, now also meaningful on former gateways.
- `identity`: the current `x509` subcommand, unchanged.
- `enable-service`, `disable-service`: kept as `systemctl` wrappers.

Standalone mode for containers and IoT is `run --foreground`, the current
`headless-client standalone`.

Code moves: a new `firezone` crate absorbs `headless-client`, the tunnel
service (`src-tauri/src/service.rs` and the `firezone-client-tunnel` bin) and
`src-cli`. The Tauri package keeps only the GUI. The `gateway` crate goes away
once the data plane is unified; before that, `firezone run` selects today's
gateway event loop when the credential is a gateway token or the init payload
lists served sites, so packaging can collapse ahead of the state merge.

In-place upgrade from the gateway deb:

- `Replaces`, `Provides`, `Conflicts` on `firezone-gateway` so `apt upgrade`
  swaps packages. The GUI deb keeps bundling the daemon and conflicts with
  the `firezone` package.
- `firezone.service` with `Alias=firezone-gateway.service` so existing
  `systemctl` habits and monitoring keep working. Drop-ins under
  `firezone-gateway.service.d` do not carry over; the postinst copies them.
- Legacy inputs keep working: `/etc/firezone/gateway-env`,
  `/etc/firezone/gateway-token` via `LoadCredential`, `FIREZONE_ID` from
  `gateway-preset-env`. The token still verifies after the table merge, and
  the device row is matched by the token's device id, or by site and
  `firezone_id` for multi-owner tokens, so addresses, slug and site
  assignments survive.
- `firezone-gateway-init` ships unchanged as an optional `ExecStartPre` that
  the upgrade keeps enabled on hosts that had the gateway package, so running
  gateways keep their sysctl and masquerade rules. New installs follow the
  docs instead. The unit keeps `CAP_NET_ADMIN` and adds `CAP_SYS_PTRACE` for
  the IPC peer check.
- Identity files stay where they are (`/var/lib/firezone/gateway_id`, the
  client `firezone-id.json`) so `firezone_id` does not change on upgrade.
- Docker: image `firezone/firezone`; `firezone/gateway` and
  `firezone/headless-client` tags published as aliases for the window. The
  docker init scripts collapse to one.

Portal side: one component `firezone` with user agent `firezone/x.y.z`.
`Portal.Version` and `ComponentVersions` map it onto the existing gateway and
headless gates; release names `firezone-x.y.z` replace `gateway-*` and
`headless-client-*` in `cd.yml` and the releases endpoint.

The daemon runs as the `firezone` user with `CAP_NET_ADMIN`, as the gateway
does today. DNS control through systemd-resolved is authorized by a polkit
rule shipped in the package; `resolv.conf` control is documented as requiring
root and is not the default. Windows follows the same two-binary shape
(`firezone.exe` as the service, GUI MSI depends on it); it serves through
the userspace forwarder only (2.3).

### 2.5 Admin UI

Sites stay, reframed. They are the one way resources reach devices, and the
client apps already group resources by site and show site status. Direct
resource-to-device assignment is a site with one device; the UI can offer that
as a shortcut without a second model.

Navigation: Resources, Groups, Policies | Sites, Devices | Actors, Service
Accounts | Logs | Settings. Settings is unchanged.

**Devices** lists every device. Columns: device (name, slug), users (actors
seen; the token's service account for infrastructure), serves (site chips),
status, platform and version, trust (attested, verified), last seen. Filters
for "serves a site" and "has users".

**Add device** replaces "Deploy gateway" and lives on both Devices and a Site:

1. Platform: Linux (apt, systemd script, Docker, Terraform), Windows, macOS,
   iOS, Android (MDM profile for the last three).
2. Connect as: a service account (default "Infrastructure") or "a user will
   sign in". The first mints a device-bound token; the second creates nothing
   and shows the sign-in instructions, since user devices create their row on
   first connect.
3. Serve sites: optional multi-select, pre-filled when started from a site.
4. The token and copy-paste commands, as the deploy tabs show today.

**Device detail**: name and slug, token (rotate, revoke), users, sites served
(edit), pools containing it, sessions, active authorizations in both
directions, posture, verify.

**Sites**: list with device and resource counts and online devices. Site
detail has Devices (add existing device, add new device), Resources, and
Site tokens (list and revoke; most gateways connect with one). The Internet
Site row disappears in the last phase and the Internet resource gets a normal
site selector.

**Resources**: unchanged except the site field reads "Served by". Device pool
member pickers accept any device.

**Service accounts**: tokens tab shows device-bound tokens with the device
they belong to. "Infrastructure" is visible, read-only, with its devices.

Client apps: unchanged. Resources grouped by site with status, device pools as
today.

### 2.6 Site-to-site

One Linux host per office. Office A has LAN 10.1.0.0/16 and site "Office A"
with that host assigned to it and a CIDR resource 10.1.0.0/16 served by the site.
Office B is the mirror. Both hosts connect with one service account, say
"site routers", which is in a group with policies to both LAN resources.
Nothing new is needed: each router is excluded from serving its own LAN, so
the policy to "Office A LAN" only ever sends host B's traffic to host A. For
one-way links or more than two offices, a service account per site gives
per-site policies.

On each host the admin enables IP forwarding and adds two masquerade rules,
tunnel to LAN and LAN to tunnel, as the gateway docs describe today. On the
LAN router the admin adds a static route for the other office's prefix via the
Firezone host. Any filtering of which LAN hosts may use the tunnel is ordinary
firewall policy on that host.

Packet path: LAN host, LAN router, host A, masquerade onto the tunnel, request
access as device A, host B serves it as a gateway does today and masquerades
onto its LAN. Replies retrace the path. The far side and the flow logs see
device A as the initiator. LAN hosts get CIDR and IP resources only.

Later options, each independent: a "Connected sites" shortcut that creates
the service account, group, resources and policies; a transparent form
without NAT where the receiver routes the originating prefix back through
the tunnel. A phone or App Store Mac serving the network behind it needs no
kernel forwarding once the userspace forwarder (2.3, phase 5b) ships.

## 3. Rollout, step by step

Every step is one PR unless noted. A step lists what it changes, what it
depends on, and how it is verified. Migrations follow expand, migrate,
contract: a column or table is added and backfilled in one release, code
switches to it, and the old one is dropped in a later release. Deployed
binaries keep working through every step; the portal still serves `/gateway`
v1, so legacy endpoints are a long-lived cost.

Ordering constraint to keep in mind: the portal must serve `/device/v1`
(phase 4) before any binary that speaks it ships (phase 5). The gateway
classification fix (0.4) is not an ordering constraint: co-hosting on a
pre-fix gateway is warned about at assignment time (2.12b), not prevented.

### Phase 0: prep, no behaviour change

- **0.1 Audit: duplicate `firezone_id`.** Done 2026-10-22; figures kept privately. Read-only query listing devices that
  share `(account_id, firezone_id)` across actors or sites, and attested rows
  sharing `(issuer, serial)`. Output drives 2.15.
- **0.2 Audit: multi-owner tokens in use.** Done 2026-10-22; figures kept privately. Devices whose `gateway_token_id`
  points at a token with `site_id` set, per account. Drives the auto-join
  support in 1.11 and the comms plan.
- **0.3 Audit: version spread.** Done 2026-10-22; figures kept privately. `last_seen_version` histogram for gateways
  and clients against the `[minor-1, minor+1]` compat window.
- **0.4 Rust: classification order.** `ClientOnGateway::classify_resource`
  consults the routing table before the Internet catch-all. Unit test; the
  fuzz reference model in `tests/fuzz/src/ref_gateway.rs` mirrors it. Ships in
  the next gateway release.
- **0.5 Rust: optional `ice_role` on `CreateAuthorization`.** Default
  `Controlled`; threaded into `create_authorization`. Serde test with and
  without the field. No portal change.
- **0.6 Elixir: `Portal.Routing.select_receiver/3`.** Pure extraction of
  compatible-gateway filtering plus `Device.load_balance_gateways` from
  `client/channel/shared.ex`. Existing channel tests unchanged.
- **0.7 Elixir: one payload builder for receivers.** PSK, ICE credentials and
  flow-log token minting shared by the gateway path and the c2c path. Pure
  refactor; existing tests.
- **0.8 Docs: forwarding and masquerade per platform.** The content of
  `firezone-gateway-init.sh` as a docs page, linked from the deploy UI later.
  Stays the reference for admins who run `--no-kernel-forwarding` and manage
  NAT themselves once phase 5b lands.

- **0.9 Comms: upgrade asks for the clusters on old protocols.** A
  meaningful share of active clients and gateways still speak the pre-July
  socket protocols, concentrated in a few large accounts. No adapter can be
  retired until they move, so start the conversation early; it is not a
  blocker for any step.

### Phase 1: unified tokens

- **1.1 Migration: `actors.managed_by`.** Text, default `account`, NOT NULL,
  index on `(account_id, managed_by)`. Ecto field; `Safe.permit` refuses
  update and delete of system actors.
- **1.2 Code: provision the Infrastructure actor.** Created with every new
  account next to `Everyone` and the Internet Site (`billing.ex`, sign-up,
  billing event handler). Fixtures and seeds. Depends 1.1.
- **1.3 Migration: backfill Infrastructure actor** for every existing account,
  idempotent. Depends 1.2.
- **1.4 Code: billing and limits exclude system actors.** Seats, service
  account count, `connected_devices_per_actor`. Unit tests on `Billing`.
  Depends 1.1.
- **1.4b Code: one more free service account on every plan.** Applied where
  the ad-hoc allowance is read (seat counting, the account API, the settings
  page) rather than stored on the account, since subscription events rewrite
  the stored limits from Stripe. Customer service accounts that own routing
  devices otherwise count as today. Depends 1.4.
- **1.5 Migration: `client_tokens` columns.** `device_id` (composite FK to
  devices, cascade), `rotated_at`, `site_id` (composite FK, cascade),
  `expires_at` nullable, check `num_nonnulls(device_id, site_id) <= 1`,
  unique `(account_id, device_id, (rotated_at IS NULL)) WHERE device_id IS NOT
NULL`, partial index on `rotated_at`.
- **1.6 Code: `Portal.ClientToken` schema** for the new columns;
  `single_owner?` and `rotation_grace_hours` move over from `GatewayToken`.
  Depends 1.5.
- **1.7 Migration: `devices.token_id`.** Composite FK, SET NULL; backfill from
  `coalesce(client_token_id, gateway_token_id)`.
- **1.8 Code: session flush writes `token_id`** alongside the legacy column
  (`LatestSession.upsert_all`, `Device.latest_session_fields`). Depends 1.7.
- **1.9 Migration: copy `gateway_tokens` into `client_tokens`.** Same ids,
  `actor_id` = Infrastructure, `device_id`, `site_id`, `rotated_at` carried,
  `expires_at` and `auth_provider_id` nil, `ON CONFLICT DO NOTHING`. With the
  gateway ids present, `devices.token_id` gets its foreign key (NOT VALID,
  dangling ids cleared, validated). The flush writes `token_id` only when the
  token exists in `client_tokens`, so an unmirrored gateway token nulls the
  column instead of failing the batch. Old table untouched. Depends 1.3,
  1.5, 1.7.
- **1.10 Migration: mirror `gateway_tokens` writes by trigger.** Database
  triggers keep `client_tokens` in step with every insert, rotation stamp
  and delete on `gateway_tokens`, so pods still writing the old table during
  a rollout, and every code path that creates, rotates or revokes a gateway
  token, are covered without a code change. The copy from 1.9 runs again
  first. From here the read switch is safe at any later deploy. Depends 1.9.
- **1.11 Code: gateway tokens read from and written to `client_tokens`.**
  `verify_gateway_token/1`, rotation confirmation and the grace reaper read
  the unified table; creation and rotation write it, actor = Infrastructure;
  multi-owner tokens keep the auto-join behaviour via `site_id`; the gateway
  token delete hook's work is done by `Hooks.ClientTokens`. UI and REST
  token controllers read the unified table. Pods on the previous release
  still write `gateway_tokens`, which the trigger mirrors. Depends 1.10.
- **1.12 Code: gateway socket builds a Subject.** `authenticate/2` with
  context `:gateway` tries the `gateway` and `gateway_group` salts; socket
  assigns `subject`; session logs use `Subject.to_map`. Depends 1.11.
- **1.13 Code: gateway-side queries scoped.** `Safe.unscoped` calls in the
  gateway socket and channel become `Safe.scoped(subject)`. Depends 1.12.
- **1.14 Code: `Devices.provision_device/4`.** Generalizes
  `provision_gateway`: inserts a device and mints a device-bound token for any
  actor, default Infrastructure. Deploy UI calls it unchanged. Depends 1.11.
- **1.15 REST: token endpoints on the unified table.** Existing
  `/sites/:id/gateways/:id/token` and `/rotate` unchanged in shape; `POST
/actors/:id/client_tokens` accepts `device_id`; new `POST
/devices/:id/token`. OpenAPI. Depends 1.14.
- **1.16 UI: tokens tab** on service accounts shows device-bound tokens with
  their device; rotate available for any device-bound token. Depends 1.11.
- **1.17 Replication: drop `gateway_tokens`** from both consumer lists and
  delete `Hooks.GatewayTokens`; drop the mirror trigger. Depends 1.11.
- **1.18 Migration (contract, next release): drop `gateway_tokens`,
  `devices.client_token_id`, `devices.gateway_token_id`,
  `Portal.GatewayToken`.** Depends 1.8, 1.17 deployed.

### Phase 2: device rows and site assignment

The UI steps in this phase (2.12, 2.19 to 2.21) ship behind an account
feature flag, `unified_devices`, and are switched on for everyone at the
cutover in 3.8b, so admins see the new package and the new screens on the
same day.

- **2.1 Migration: `device_actors`.** `(account_id, device_id, actor_id,
first_seen_at, last_seen_at)`, PK on the three ids, cascading FKs. Ecto
  schema; both replication consumer lists; broadcast-only hook.
- **2.2 Migration: backfill `device_actors`** from `devices.actor_id` for
  client rows. Depends 2.1.
- **2.3 Code: client connect upserts `device_actors`** through the session
  flush queue. Depends 2.1.
- **2.4 Code: pool criteria read `device_actors`.** Own-devices and
  actor-group SQL use EXISTS on the new table; presence-based `member?`
  unchanged. Criteria tests. Depends 2.2.
- **2.5 Code: seats from `device_actors.last_seen_at`.** Billing tests.
  Depends 2.2.
- **2.6 UI: Devices "Owner" becomes "Users"**; actor detail lists devices via
  `device_actors`; actor delete hook disconnects that actor's sessions.
  Depends 2.2.
- **2.7 Migration: `site_devices`.** `(account_id, site_id, device_id,
inserted_at)`, unique on the three ids, cascading FKs. Ecto schema, `Site`
  associations, consumer lists, hook that broadcasts to the site topic.
- **2.8 Migration: backfill `site_devices`** from `devices.site_id`.
  Depends 2.7.
- **2.9 Migration: trigger mirroring `devices.site_id` writes** into
  `site_devices` for one release, so unconverted write paths stay
  correct. Depends 2.8.
- **2.10 Code: presence meta `site_ids`** from `site_devices` at connect; the
  per-site presence lookups read it. Depends 2.8.
- **2.11 Code: `Routing.select_receiver` uses `site_devices`.** Candidates are
  online devices whose `site_ids` include the resource's site, never the
  initiator itself, still limited to `type == :gateway` until 4.6. The
  client's connectable resources exclude any resource served by a site the
  device is assigned to. Depends 0.6, 2.10.
- **2.12 UI: Sites devices tab.** Reads `site_devices`; add existing device
  (picker limited to gateways until 4.6, others shown disabled with reason);
  remove device. Depends 2.8.
- **2.12b UI: co-hosting warning.** When an admin adds the Internet
  resource to a site with other resources, adds a resource to the site
  holding the Internet resource, or assigns a device to the Internet Site
  and another site, the form warns as in 2.7 and asks for confirmation. The
  REST docs carry the same sentence. Depends 2.12.
- **2.13 Code and migration: site delete keeps devices.** `site_id` FK
  becomes SET NULL; UI and REST copy; blocked while resources remain.
  Depends 2.8.
- **2.14 REST: `/sites/:id/gateways` reads `site_devices`; new `POST` and
  `DELETE /sites/:id/devices`.** Depends 2.8.
- **2.15 Migration: merge duplicate device rows.** Dry-run mode first. For
  each identity group from 0.1 keep the most recently seen row, falling back to `inserted_at` where
  `last_seen_at` is null; move
  `device_actors`, both sides of `policy_authorizations`, `site_devices`, listed
  pool ids (jsonb), posture rows; delete the rest. Announce slug changes.
  Depends 0.1, 2.2, 2.8.
- **2.16 Migration: identity uniqueness without actor.** Unique `(account_id,
firezone_id) WHERE firezone_id IS NOT NULL` and `(account_id, issuer,
serial)`; drop the actor-scoped indexes, `device_type_client_fields` and
  `device_type_gateway_fields`; `actor_id` nullable. Depends 2.15.
- **2.17 Code: lookups without actor.** Client socket `find_by_firezone_id`
  by account; attested lookup in `device_trust.ex` by account; `Device`
  changeset validations by presence of fields rather than `type`. Depends
  2.16.
- **2.18 Code: evaluator accepts any device.** `Policies.Evaluator`,
  `Condition`, `Postures.Evaluator` drop the `type: :client` guards; the
  session actor is passed explicitly. Depends 2.17.
- **2.19 UI: Devices page lists every device** with "Serves" from
  `site_devices` and the two filters. Depends 2.10.
- **2.20 UI: device detail** with sites-served editor, users, pools, token
  rotate. Depends 2.12, 1.16.
- **2.21 UI: Add device wizard** replaces Deploy gateway on Sites and Devices,
  calling `provision_device`, deploy tabs reused, sites multi-select writes
  `site_devices`. Depends 1.14, 2.12.
- **2.22 Code: `devices.type` stays maintained** as a legacy value (gateway
  when provisioned with Infrastructure, client otherwise) for `/clients`,
  component versions and protocol selection until phase 6. No PR of its own;
  a rule each step above respects.

### Phase 2b: site-to-site

- **2b.1 Docs: site-to-site guide.** Service account, group, two LAN
  resources, two policies, the forwarding and masquerade commands from 0.8,
  and the static route. No code. Depends 2.11, 2.21.

### Phase 3: Linux binary collapse

- **3.0 Elixir: compatibility by protocol range.** Today a client on minor
  `m` accepts gateways in `[m-1, m+1]` and two clients must share a minor.
  One binary playing both roles cannot satisfy that with one version. New
  binaries send `proto_min` and `proto_max` as connect parameters; legacy
  clients are mapped to `[m, m]` and legacy gateways to `[m-1, m+1]`, which
  reproduces today's rules exactly. Compatible means the ranges overlap.
  Presence meta carries the range; `Routing.select_receiver` and the c2c
  peer check read it; `Portal.Version` keeps only feature gates. Policy:
  `firezone` supports two minor versions back on both sides (see 3a). Must
  be live before any unified binary ships.
- **3.1 Rust: `firezone` crate.** New bin `firezone` with `run`, `sign-in`,
  `sign-out`, `identity` wrapping today's headless main; `firezone-headless-
client` becomes an alias bin of the same crate. CI builds both.
- **3.2 Rust: tunnel service moves in.** `service.rs` and the
  `firezone-client-tunnel` bin leave the Tauri package; `firezone run` serves
  the IPC socket; `linux-group.sh` no longer builds Tauri. Alias bin kept.
  Depends 3.1.
- **3.2b Rust: version check on the IPC pipes.** `Hello` carries the daemon
  version and the GUI sends its own; a mismatch surfaces a "restart or
  upgrade" message instead of a deserialization error. Same check between
  the CLI and the GUI. No compatibility window: GUI and daemon ship in one
  package (3.6), so skew only exists during an upgrade. Depends 3.2.
- **3.3 Rust: CLI moves in.** `src-cli` subcommands become `firezone`
  subcommands; IPC peer-check allowlist learns the new exe name;
  `firezone-cli` alias kept. Depends 3.2.
- **3.4 Rust: gateway main moves in.** `firezone run --role gateway`, with
  the role defaulting from the alias name `firezone-gateway` or the presence
  of `/etc/firezone/gateway-token`; `authenticate`, `enable-service`,
  `disable-service` move from `manage.rs`. Interim until 5.9. Depends 3.1.
- **3.5 Packaging: `firezone` deb and rpm.** `/usr/bin/firezone`,
  `firezone.service` running as the `firezone` user with `CAP_NET_ADMIN`
  and `Alias=firezone-gateway.service`, sysusers and tmpfiles from the
  gateway, a polkit rule granting that user systemd-resolved DNS control,
  init script as optional `ExecStartPre` enabled by the upgrade postinst,
  `Replaces`/`Provides`/`Conflicts` on `firezone-gateway`, drop-ins and
  preset env copied. Depends 3.4.
- **3.6 Packaging: GUI package stays self-contained.** GUI deb and rpm ship
  the same `firezone` binary and `firezone.service` as the `firezone`
  package, plus the GUI, with `Provides: firezone` and `Conflicts: firezone`
  so a machine has one daemon. One download and one install command on
  desktops, as today; lockstep between GUI and daemon is automatic.
  `firezone-client-tunnel.service` aliases to `firezone.service`; state
  directory kept and re-owned to the `firezone` user; desktops that used
  `resolv.conf` DNS control get a release note. Depends 3.3, 3.5.
- **3.7 CI and release.** `firezone` artifacts (deb, rpm, tarball, docker
  `firezone/firezone` plus alias tags), release name `firezone-x.y.z` in
  `cd.yml` and `publish-release.yml`, apt and rpm sync. Depends 3.5.
- **3.8 Portal: component `firezone`.** `Version.fetch_version` parses
  `firezone/`; `ComponentVersions` component mapped onto the gateway and
  headless gates; releases endpoint; deploy UI commands become `apt install
firezone` and `firezone authenticate`. Depends 3.7.
- **3.8b Cutover and comms for R2.** On the day `firezone` 1.7.0 is
  published: flip the `unified_devices` flag for every account, switch the
  deploy commands, publish the blog post on the package rename and the
  in-place upgrade, and email the admins of every account with a gateway
  through the existing mailer, pointing at the post. Depends 3.8.
- **3.9 Docs: install and upgrade notes.** Depends 3.8.
- **3.10 Remove alias bins and tags** after the window. Depends 3.9.

### Phase 4: one channel core and `/device/v1`

- **4.1 Elixir: relays into Core.** Relay selection and `relays_presence`
  shared by both channels. Pure refactor; existing tests.
- **4.2 Elixir: ICE candidate relay into Core.** Both directions, both peer
  kinds. Depends 4.1.
- **4.3 Elixir: one inbound cache.** `Cache.Gateway` and
  `Cache.Client.Authorizations` become `Cache.Inbound`. Depends 4.2.
- **4.4 Elixir: receiver handling into Core.** `create_authorization` with a
  `target` of self or resource and the signed-ref ack; the c2c auto-ack stays
  as a per-adapter option. Depends 0.7, 4.3.
- **4.5 Elixir: initiator handling into Core.** `request_access` and
  `request_authorization` on `Routing.select_receiver`. Depends 4.4.
- **4.6 Elixir: capabilities.** Presence meta `capabilities`;
  `select_receiver` filters by capability and version; legacy gateways default
  to full routing, legacy clients to self-only; the `type == :gateway` limits
  from 2.11 and 2.12 go away. Pool targeting rules wait for 6.3, since device
  pools see very little production traffic. Depends 4.5.
- **4.7 Elixir: change handling into Core.** Account, device, resource,
  policy, site-device and authorization changes in one place. Depends 4.5.
- **4.8 Elixir: registration policy per adapter.** Last-wins on
  `/device/v1` with a `superseded` reason; the `/gateway` v1 and v2 adapters
  keep first-wins, since deployed gateways exit permanently on any
  `disconnect` (2.7). Depends 4.7.
- **4.9 Elixir: `/gateway` v1 and `/gateway/v2` as adapters** over Core:
  views and message names only. A meaningful share of active gateways are below 1.5.3 and
  still on v1. Existing gateway channel tests unchanged. Depends 4.8.
- **4.10 Elixir: `/client` v1, v2 and v3 as adapters** over Core, including
  the c2c auto-ack. A meaningful share of active clients are still on v1 or v2.
  Existing client channel tests unchanged. Depends 4.9.
- **4.11 Protocol: `/device/v1` message set.** Init with `resources`,
  `sites_served`, `local_resources` and inbound `authorizations`, plus the
  `local_resource_*` pushes; `create_authorization` with `ice_role` and
  `target`; ICE messages keyed by `device_id`; `set_capabilities`. Written
  down in `tunnel-proto` docs and the Elixir views. Depends 4.10.
- **4.12 Elixir: `/device/v1` socket and channel.** Adapter over Core; auth
  accepts the client and gateway salts; endpoint route; channel tests.
  Depends 4.11.
- **4.13 Elixir: feature gates** for `/device/v1` on top of the protocol
  range from 3.0. Depends 3.0, 4.12.

### Phase 5: one data-plane state

- **5.1 Rust: `PeerInbound`.** One per-peer type with a set of targets, used
  by both existing states in place of `ClientOnClient` and
  `ClientOnGateway`. Fuzz corpus unchanged. Depends 0.4.
- **5.2 Rust: `DeviceId`.** `ClientId` and `GatewayId` become aliases of one
  id; node keyed by `DeviceId`. Depends 5.1.
- **5.3 Rust: ICE role and presets from the portal** on both sides. Depends
  0.5, 5.2.
- **5.4 Rust: `DeviceState`.** `ClientState` plus the receiver half (peers,
  flow tracker, TUN DNS server hooks, `ResolveDns` events);
  `Tunnel<DeviceState>` with one `poll_next_event`; `Io` binds the L4 DNS
  servers only when serving. Depends 5.3.
- **5.5 Rust: bypass resolvers** for DNS-resource lookups when the device
  also runs DNS control. Depends 5.4.
- **5.6 Rust: classification pipeline** in `PeerInbound`: self, authorized
  routing table, deny if inside any resource the device serves (known from
  the `/device/v1` inbound view), Internet with reject list, deny; hairpin
  check. Depends 5.4.
- **5.7 Fuzz: `SimDevice`, `RefDevice`, `StubPortal`** with site devices,
  capabilities and `ice_role`; corpora regenerated by the nightly job.
  Depends 5.6.
- **5.8 Rust: tunnel-bench and loadtest** on `DeviceState`. Depends 5.4.
- **5.9 Rust: `firezone run` on `DeviceState` over `/device/v1`.**
  Capabilities reported (`route_resources` from the forwarding sysctl on
  Linux until phase 5b, then from the forwarder that came up;
  `dns_recursion`, `iceless`); `--role` from 3.4 removed; gateway event loop
  and crate deleted. Depends 4.12 deployed, 5.7.
- **5.10 Integration tests** on one image for both roles. Depends 5.9.
- **5.11 Portal: version gate** marking `firezone >= x` as routing-capable
  over `/device/v1`. Depends 5.9.
- **5.12 Cutover and comms for R3.** Blog post on sites as device
  assignments and co-hosting; targeted email to admins of accounts with
  gateways below the routing-capable version, pointing at the post and the
  upgrade path (the conversation 0.9 started). Depends 5.11.

### Phase 5b: forwarding owned by the daemon

- **5b.1 Rust: `Forwarder` trait** behind the served branch of
  `PeerInbound`'s outbound translation, with the TUN write as the first
  implementation; selection order kernel, userspace, none; the capability
  report carries which one came up. Depends 5.9.
- **5b.2 Rust: Linux kernel forwarder owns host setup.** Sysctls and the
  `firezone` nftables table created on the first resource to
  serve, torn down when serving stops; prior sysctl restored on shutdown
  only if the daemon changed it; `--no-kernel-forwarding` and the matching
  environment variable; falls through without `NET_ADMIN`. Docker image
  and deb drop the init script. Depends 5b.1.
- **5b.3 Rust: userspace forwarder, TCP and UDP.** smoltcp through
  `l3-tcp` paired with host sockets per connection; per-flow UDP sockets;
  reset and destination-unreachable mapping from socket errors; flow-log
  records from the forwarder. Depends 5b.1.
- **5b.4 Rust: userspace forwarder, ICMP.** Echo through the platform ping
  APIs with the identifier table from 2.3; time exceeded relayed where the
  API reports it; error replies to the peer for unreachable resources.
  Depends 5b.3.
- **5b.5 Fuzz: userspace forwarder in the simulation** behind the trait
  from 5b.1, so the existing TCP, UDP and ICMP echo probes cover both
  paths; a reference-model expectation for the error mapping. Depends 5b.4.
- **5b.6 Windows: `firezone.exe` serves.** Userspace forwarder only; the
  MSI install test adds a served resource and pings it through a second
  device. Depends 5b.4.
- **5b.7 Integration tests: both forwarders** on the one image from 5.10,
  the Linux container once with and once without `NET_ADMIN`, with ping,
  TCP and UDP downloads. Depends 5b.2, 5b.4.
- **5b.8 Portal and docs.** Device detail shows the forwarder in use; the
  0.8 page gains the opt-out flag and the Windows note. Depends 5b.1.

### Phase 6: contract

- **6.1 REST: `/clients` and `/sites/:id/gateways` without `type`.**
  `/clients` returns devices with at least one user; gateways are a site's devices.
  Deprecation headers. New `/devices`. Depends 2.19.
- **6.2 Code: component and version logic by user agent only.** Depends 3.8.
- **6.3 Code: pool criteria and pickers accept any device; pools never target
  legacy gateways.** Depends 4.6.
- **6.4 Migration: drop `devices.type`.** Depends 6.1, 6.2, 6.3.
- **6.5 Migration: drop `devices.site_id` and its trigger, drop
  `devices.actor_id`.** Depends 2.9 and 2.17 deployed.
- **6.6 Code and migration: Internet Site becomes a normal site.** Flip
  `managed_by`, drop the pairing validation and the pinned row; Internet
  resource gets a site selector. Depends 0.4 in the fleet, 5.11.
- **6.7 UI: wording sweep.** "Gateway" becomes "device" wherever it means
  the machine; nav and page copy. Depends 2.21.
- **6.8 Remove legacy socket adapters** after the compat window. Separate
  decision, far later.

## 3a. Deploy points and releases

The portal deploys on every merge. These are the points where order matters.

| Point | Must be live                               | Release                                                                                     |
| ----- | ------------------------------------------ | ------------------------------------------------------------------------------------------- |
| D1    | 0.6, 0.7                                   | R1: gateway 1.6.5 with 0.4 and 0.5                                                          |
| D2    | 1.1 to 1.17                                | none                                                                                        |
| D3    | 1.18, one release after D2 settled         | none                                                                                        |
| D4    | 2.1 to 2.21                                | none                                                                                        |
| D5    | 3.0, 3.8                                   | R2: `firezone` 1.7.0 and Linux GUI 1.7.0, legacy sockets, interim role switch; cutover 3.8b |
| D6    | 4.1 to 4.13                                | R3: `firezone` 1.8.0 on `DeviceState` over `/device/v1`                                     |
| D7    | 5.11 after R3 is in the fleet              | cutover 5.12                                                                                |
| D8    | 6.1 to 6.7 after 2.9 and 2.17 settled      | R4: `firezone` minor dropping alias bins (3.10)                                             |
| D9    | 6.8 once 0.9 has cleared the old protocols | none                                                                                        |

**Customer-facing compatibility.** Today's rule: a Gateway must be within one
minor version of the Client in either direction, and Clients connecting to
each other must share a minor. That stays for the existing components. For
`firezone`, which plays both roles, each release states absolute versions:
it supports Clients from the two previous minor versions and Gateways from
the two previous minor versions, and connects device to device with Clients
on those same versions. Internally the ranges are legacy clients `[m, m]`,
legacy gateways `[m-1, m+1]`, `firezone` 1.7 `[5, 7]`, `firezone` 1.8
`[6, 8]`; the width is one table in `Portal.Version`.

| Release             | Serves Clients | Reaches Gateways         | Device to device                 |
| ------------------- | -------------- | ------------------------ | -------------------------------- |
| Gateway 1.6.5 (R1)  | 1.5, 1.6, 1.7  | n/a                      | n/a                              |
| `firezone` 1.7 (R2) | 1.5, 1.6, 1.7  | 1.5, 1.6, `firezone` 1.7 | Clients 1.5, 1.6, `firezone` 1.7 |
| `firezone` 1.8 (R3) | 1.6, 1.7, 1.8  | 1.6, `firezone` 1.7, 1.8 | Clients 1.6, `firezone` 1.7, 1.8 |

Apple, Android and the Windows GUI need no release. PR count is about 98
code PRs plus 3 docs PRs before merging small neighbours: phase 0 has 4,
phase 1 has 19, phase 2 has 22, phase 3 has 12, phase 4 has 13,
phase 5 has 12, phase 5b has 8, phase 6 has 8.

## 4. Decisions taken

1. **Daemon user on Linux:** the `firezone` user with `CAP_NET_ADMIN`, polkit
   rule for systemd-resolved, `resolv.conf` control documented as root-only.
2. **Billing:** customer service accounts that own routing devices count as
   any actor does today; every plan gets one additional free service account
   (step 1.4b). The Infrastructure actor never counts.
3. **Binary shape:** one executable, `firezone`, with `run` as the daemon.
4. **Site assignment:** explicit rows only; rules not planned.
5. **Forwarding:** on Linux the daemon owns kernel forwarding (sysctls and
   an nftables table it creates), enabled only once it has a resource to
   serve, with `--no-kernel-forwarding` as the opt-out; everywhere else, and
   as the Linux fallback, a userspace forwarder in smoltcp with ICMP echo
   through the platform ping APIs. Windows serves through userspace only.

## 5. Risks

- `firezone_id` collisions when identity stops being actor-scoped: a small
  number of groups on both sides, handled by 2.15.
- DNS self-recursion on a device that is both client and router.
- Hairpin between peers through a routing device must stay denied.
- Legacy multi-owner tokens change lookup key from (site, `firezone_id`) to
  (system actor, `firezone_id`) plus site assignment.
- Deleting a site no longer deletes devices.
- One binary, two roles, one version: solved by protocol ranges (3.0), which
  must ship before R2 or the unified binary is incompatible with half the
  fleet in one role or the other.
- The userspace forwarder costs a host socket and userspace copies per
  flow, so throughput and connection counts sit below kernel forwarding;
  UDP traceroute through it is best effort. Kernel forwarding stays the
  Linux default for that reason.
- A daemon that edits sysctls and nftables on a host it shares with other
  firewalls: contained by a table of its own and by never touching the
  host before there is a resource to serve.
- Rollback: phases 1 to 3 are expand-only or code-only with downs; phase 4 is
  code; phase 5 ships a new binary against adapters; phase 6 is the only
  irreversible step.

## 6. Sizing

| Phase | Steps | Size      |
| ----- | ----- | --------- |
| 0     | 9     | small     |
| 1     | 19    | medium    |
| 2     | 23    | medium    |
| 2b    | 1     | docs only |
| 3     | 13    | medium    |
| 4     | 13    | large     |
| 5     | 12    | large     |
| 5b    | 8     | medium    |
| 6     | 8     | medium    |
