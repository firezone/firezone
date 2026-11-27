# Unified devices: merging the Client and Gateway roles

Status: draft plan. Revised 2026-10-22 against `main` at 698b4b457. Device
identity replanned 2026-11-22 as Phase I, before the unification.

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
- The token says who acts, and a portal-issued certificate says which machine
  connects. Device identity ships first, in today's Clients and Gateways
  (Phase I), before the unification merges.

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
  copied into a new shared token table with ids intact and every deployed
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

**Device** is the machine, keyed by `firezone_id` or, for MDM-managed
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

**Actor** gains the type `legacy_gateway`. Each account gets one, and it
owns the existing Gateway tokens (decision 7). It takes no seat, is not in `Everyone`, cannot sign in, and is
exempt from `connected_devices_per_actor`.

**Token** (`device_tokens`, new) absorbs both client tokens and the two
gateway token kinds:

| Column                  | Meaning                                                                                                                                                                                                                                             |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `device_id` (nullable)  | device-bound token, minted by the deploy flow for a pre-created device. Replaces single-owner gateway tokens and gives headless clients the same pre-provisioned deploy path.                                                                       |
| `rotated_at` (nullable) | rotation grace, as gateway tokens today                                                                                                                                                                                                             |
| `site_id` (nullable)    | auto-join site for a device created on first connect with this token. Replaces multi-owner site tokens, which most gateways still use. Creation stays closed, as the API sunset already says; verification, listing and revocation are first class. |

`expires_at` becomes nullable. Every token belongs to an actor, so every
session has a Subject. `gateway_tokens` and `client_tokens` are dropped
after their rows are copied.

There is one kind of token and no `type` column (decision 11). Every new
token is signed with the `"device"` salt. The old `"client"` and `"gateway"`
salts stay only as fallbacks for tokens issued before the change. Each socket
checks its salts in order and then accepts only the rows of its shape, in the
lookup query:

| Socket       | Salts checked                            | Rows accepted                                           |
| ------------ | ---------------------------------------- | ------------------------------------------------------- |
| `/client`    | `"device"`, then `"client"`              | `site_id` null, and `device_id` null or a client device |
| `/gateway`   | `"device"`, then `"gateway"`             | `site_id` set, or `device_id` a Gateway device          |
| `/device/v1` | `"device"`, `"client"`, then `"gateway"` | any                                                     |

The id and hash find the row; the shape decides if this socket may use it.
Without it, a Site token would connect to `/client` as its owner. The REST
token endpoints use the same rules, so a `client_tokens` scope never reaches
a Gateway token and the reverse. A client or Gateway that upgrades to
`/device/v1` keeps its token. Adding the device to a Site adds a
`site_devices` row and does not change the token or `devices.type`, so going
back to the old binary keeps working. The `"client"` fallback goes once the
last client token issued before the change expires; the `"gateway"` fallback
goes once no Gateway uses a token issued before the change.

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
  and gateways without 0.4 do not route the site's other resources while
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
seen; the token's service account for infrastructure), "Routes for" (site
chips), status, platform and version, trust (device trust and verified), last
seen.
Filters for "routes for a site" and "has users". The label is "Routes for",
not "Serves": the verb matches the `route_resources` capability, and a bare
"Routes" would read as a list of prefixes.

**Add device** replaces "Deploy gateway" and lives on both Devices and a Site:

1. Platform: Linux (apt, systemd script, Docker, Terraform), Windows, macOS,
   iOS, Android (MDM profile for the last three).
2. Connect as: a service account or "a user will
   sign in". The first mints a device-bound token; the second creates nothing
   and shows the sign-in instructions, since user devices create their row on
   first connect.
3. Routes for: optional site multi-select, pre-filled when started from a
   site.
4. The token and copy-paste commands, as the deploy tabs show today.

**Device detail**: name and slug, token (rotate, revoke), users, "Routes
traffic for" with its sites (edit), pools containing it, sessions, active authorizations in both
directions, posture, verify.

**Sites**: list with device and resource counts and online devices. Site
detail has Devices (add existing device, add new device), Resources, and
Site tokens (list and revoke; most gateways connect with one). The Internet
Site row disappears in the last phase and the Internet resource gets a normal
site selector.

**Resources**: unchanged except the site field reads "Routed through". Device pool
member pickers accept any device.

**Service accounts**: tokens tab shows device-bound tokens with the device
they belong to. The legacy Gateway actor is never shown (decision 7).

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

Ordering constraints to keep in mind: device identity (Phase I) ships in
today's Clients and Gateways before any unification step that users can
see. The portal must serve `/device/v1`
(phase 4) before any binary that speaks it ships (phase 5). The gateway
classification fix (0.4) is not an ordering constraint: co-hosting on a
pre-fix gateway is warned about at assignment time (2.12b), not prevented.

### Next steps (2026-11-18)

No entity changes in the portal for now: sites, `site_devices`, policies and
pools stay as they are, so the connlib work is not blocked on model changes.
Ideas for a simpler admin UI (devices or users set directly on a resource,
sites created automatically) wait for customer evidence. Devices in several
sites (2.10 as a list, 2.12, lifting the one-site rule from #16288) is a
constraint change, not a new entity, and waits for a decision.

When devices can be in several sites, a site-token connect must still find a
gateway only through its home site, the site of the token it connects with.
Sites an admin adds only affect routing. The gateways flagged
`firezone_id_exempt` are mostly cloned VMs that share a `firezone_id` across
sites. Each needs its own row: never merge them, and never widen the lookup to
every site a device routes for, or both clones resolve to one row and the
legacy socket refuses the second (first-wins). The same rule is a comment on
`find_gateway` in `PortalAPI.Gateway.Socket`.

First, every portal change that users do not see, so that most of the code
has changed and settled before anything visible ships. In order, one PR per
deploy:

1. One builder for the secrets a receiver gets (preshared key, ICE
   credentials, flow-log tokens), shared by the Gateway path and the
   client-to-client path (0.7).
2. One shared channel core, moved one area at a time: relay selection and
   relay presence, ICE candidates, caches, the receiver side, the initiator
   side, and handling of changes (4.1 to 4.10).
3. Policy checks that accept any device (2.18) and device validation by the
   fields present instead of `type` (2.17, changeset part).
4. One function that creates a device and its token (1.12).
5. Code that reads a device's sites as a list, while each device still has
   exactly one (2.10).
6. The `/device/v1` endpoint next to the old ones (4.11, 4.12). Nothing
   connects to it until a new binary ships.
7. Version check by range (3.0), last, with a test that the old and new
   rules agree for every legacy version pair.

**Deploy boundaries.** None of these needs a migration. The boundary that
matters is the mixed cluster: during a rolling deploy, old and new portal
nodes run together, and channel processes on one node send messages to
channel processes on the other. So:

- Moving code without changing what crosses between processes is one
  deploy. This covers 1, 3 and 4, and every part of 2 that keeps its
  messages.
- Changing a message between channel processes (the `Portal.PG.deliver`
  tuples such as `:create_authorization`, `:allow_access`,
  `:request_connection`, `:client_device_access_authorized`, the ICE
  candidate tuples, `:revoke_pair_access`, `:disconnect`) takes three
  deploys: receivers accept the old and the new shape, then senders switch,
  then the old shape goes. Any part of 2 that unifies the Gateway and
  client-to-client messages follows this.
- Changing presence meta follows the same rule, because every node reads
  every other node's meta. For 5: write `site_ids` next to `site_id`, then
  read `site_ids` with a fallback to `[site_id]`, then stop writing
  `site_id`. For 7: write the range, then read it with a fallback to the
  range derived from the version, then drop the fallback for `/device/v1`
  devices.

After that, the visible steps: 1.12's callers in the UI, 2.19, 2.21 (Linux
deploy tabs only until phase 5b), 2.20 with 1.14, 2.23, 2.13. Rust in
parallel: 0.4, 0.5, the phase 3 drafts, then 5.1 and 5.2.

**Receiving side: one message between portal nodes.** Consolidate to the
shape `/device/v1` needs, so the unified binary adds an adapter, not a path.
Today the initiating client channel sends `:create_authorization` to a
gateway channel, which replies `:connect` once the gateway echoes the signed
ref, and `:client_device_access_authorized` to a client channel, which
replies `:device_access_acked` at once. Both become:

- `{:authorize, {pid, ref}, request}` to the receiver's channel. The request
  carries ids, the cacheable resource, the secrets from `connection_secrets`,
  the expiry, the policy authorization and the initiator's iceless
  capability. The receiver renders payloads for its own protocol version,
  which also ends the client-to-client payload being rendered with the
  initiator's session.
- `{:authorized, ref, reply}` back to the initiator: the receiver's id, keys,
  addresses, name, slug and site, and the resolved `use_iceless`.

The receiver's adapter only picks the ack: the device echoes the signed ref
(gateways, and every `/device/v1` device) or the channel acks at once
(clients on `/client` v1 to v3).

Deploys, each after the previous one is fully rolled out:

1. Receivers handle `:authorize` and initiators handle `:authorized`, next to
   the old messages. Senders do not change.
2. Senders switch to `:authorize` and `:authorized`.
3. The old messages and their handlers go. Requests time out after 15
   seconds, so a few minutes after deploy 2 none are in flight.

### `/device/v1` plan (2026-11-19)

Done on main: the shared channel modules (`Session`, `Relays`, `Durability`,
`Authorizations`), one receiver message (`:authorize` and `:authorized`), one
ICE message `{tag, %{type, id}, candidates}`, one presence tracker with
`site_ids` as a list, sites through `site_devices`, `device_tokens` with the
`client`, `gateway`, `gateway_group` and `device` salts, and lookup by account
and `firezone_id`.

Decisions:

- **Every device can serve.** Serving is decided by site assignment, not by a
  capability, so `nat` is gone. The only capability is `tun`: a device with a
  TUN interface can initiate and be a device pool target. Legacy defaults:
  clients `[:tun]`, gateways `[]`.
- **Only sockets that can serve put sites in presence.** `/gateway` and
  `/device/v1` write the device's `site_ids`; `/client` v1 to v3 always write
  `[]`. Routing reads presence only, so a legacy client binary is never
  selected to serve, even if its device row has a `site_devices` row from an
  earlier `/device/v1` connect. Refusing to assign such a device to a site is
  UX only.
- **`type` is legacy.** A row with `type = NULL` is a device from a unified
  binary, found only by its certificate. A row with `client` or `gateway`
  is a legacy record from an older binary. An enrolled legacy record that a
  unified binary connects with becomes `type = NULL` and keeps its id.
- **Ranges are declared** (decision 10): `proto_min` and `proto_max` connect
  parameters, stored as declared (no portal floor); the pair's minor travels in the
  `:authorize` request as an added key.

Steps, one PR per deploy. Nothing connects to `/device/v1` until the unified
binary ships, so none of them is visible to users. Adding a presence key that
readers default when missing is one deploy, and no step changes a message
between portal nodes.

1. **A1 Ranges in presence (3.0).** Legacy sockets write the range derived from
   the version; `Routing` and the c2c peer check read it with that fallback.
   Test: old and new rules agree for every legacy version pair. Reuses #15914.
2. **A2 `tun` and `site_ids` routing.** Presence `capabilities`; receivers are
   selected by `site_ids`, not `type`; legacy client sockets write
   `site_ids: []`; pool targets and initiators need `:tun`.
3. **A3 Serving receiver out of the Gateway channel** into a shared module:
   resource cache hydration, served resource, site and policy changes,
   `:authorize` for a resource target, the `authorization_created` echo,
   `revoke_pair_access`, `reject_access`. Pure move.
4. **A4 Client handlers chainable**, so one channel uses both halves.
   `:authorize` dispatches on the target: resource to the serving half, self
   to the client receiver.
5. **A5 Registration policy as an option**: `:last_wins` with a `superseded`
   reason, or `:first_wins`. Legacy behaviour unchanged.
6. **B1 Message set (4.11)**: docs and views. Init with `resources`,
   `sites_served`, `local_resources` and inbound `authorizations`;
   `local_resource_*` pushes; `create_authorization` with `ice_role`,
   `target` and the pair's minor; `device_id` for every peer field. Reuses
   #15920. Jamil and Thomas approve it before the first binary that speaks
   it ships; until then shapes may change, after that a shape change needs a
   new socket version.
7. **B2 `/device/v1` socket (4.12)**: all four salts, subject, lookup by
   account and `firezone_id`, last-wins, served site from the site token or
   `site_devices`, `capabilities`, `proto_min` and `proto_max`. No feature
   flag: only a new binary connects here, so the release is the gate. The
   socket makes every check the legacy sockets make.
8. **B3 Channel, initiating half**: `/client/v3` parity with `device_id`.
9. **B4 Channel, serving half**: the device always echoes the signed ref. In
   ICE and `:authorized`, the sender `type` is the device's role in that pair,
   so legacy peers keep their current payloads.
10. **B5 Feature gates (4.13)** from the pair's range.

B3 and B4 test every pair with a legacy peer: the device initiates to a
gateway, a client initiates to the serving device, and client to client with
a pool target. In each, the legacy side gets the payloads it gets today.

### Phase I: device identity, before the unification (replanned 2026-11-22)

**This comes first, on today's binaries.** Thomas and Jamil agreed to ship
strong device identity in the current Client and Gateway releases, on
`/client` and `/gateway`, before any unification work merges. The
unification then only merges roles. The 1.7 PRs (#16645, #16719, #16720)
stay drafts until this phase is done.

Problem: a device reports its own `firezone_id`, and the portal trusts it
(GHSA-2gj4-h7fw-gcp5). A lookup that finds a row by `firezone_id` alone lets
one credential land on another device's row. Some Gateways share a
`firezone_id` across Sites, and some Clients share one across actors, so
merging the two kinds of rows today needs many special cases.

Fix: every device on a new release holds a private key that never leaves
it, and a certificate that the portal issues for that key. The certificate
says which machine connects. The token says who acts. When a device shows
its certificate, the portal finds its row by the certificate and ignores the
reported `firezone_id`.

**Decisions (2026-11-22).**

- **One CA per account.** Every key is P-256: the CA keys and the device
  keys. In the cloud each account has its own P-256 key in Azure Key Vault
  Standard: software-protected, not exportable, and every signature is made
  in Key Vault with the portal's managed identity.
  A new account gets its CA from a background job; a periodic job queues the same job for every account without a CA. Without Key Vault (on-prem, dev and test) each account has its own P-256 key in the database. A customer that needs a FIPS 140
  Level 3 key gets a new CA with an `EC-HSM` P-256 key in a Premium vault later,
  as a rotation. The CA certificate is valid for 20 years.
- **Certificates live 90 days.** The device renews at a random point
  between 55% and 70% of the lifetime with its current certificate, so
  devices that enrolled together do not renew together.
- **Rotation is internal.** Admins never see it. Firezone ops replaces an
  account's CA in place: a new key and certificate on the same row, and the
  old Key Vault key version is disabled. There is no overlap. The portal
  refuses the old certificates, and each device re-enrolls with its token
  (case 3 below) at its next connect. Routine rotation disconnects nothing,
  so the re-enrollments spread over the next day (Azure ends every
  WebSocket within 24 hours). An emergency rotation also disconnects every
  device in the account; then all of them re-enroll at once.
- **Signing is throttled by Key Vault**, per vault and region: about 400
  signatures a second for software keys, 2 key creations a second. When
  Key Vault answers 429, the portal answers 429 to the device at once (no
  retries in the portal). The device backs off exponentially from 1 second
  to 5 minutes with jitter. It never drops a working certificate until it
  has stored the new one.
- **The mTLS host is the device trust host** (`mtls_external_url`). Phoenix
  ends the TLS handshake there.
- **Key storage:** the key belongs to the machine, not to a user. TPM 2.0 on
  Windows and Linux. On macOS both builds run the tunnel as a system
  extension: the key is a Secure Enclave key (every Mac with a T2 chip or
  Apple silicon), and the System keychain holds its CryptoKit
  `dataRepresentation`, which only that Secure Enclave can use. Older Macs
  get a software key in the System keychain. On iOS the
  app extension keeps it in the app group keychain, in the Secure Enclave.
  Keystore or StrongBox on Android. Where none is available (containers,
  VMs without a vTPM, older Macs), a software key in the state directory or
  keychain. A platform can ship with a software key first and move to its
  hardware store later without a protocol change. The portal does not
  record where the key is kept; hardware attestation brings its own proof
  later.
- **Two separate things.** _Verified_ is an admin's approval of the
  device (`verified_at`, as today). _Device trust_ is what the current
  connection proved with its certificate, worked out at every connect:
  - _None_: no certificate (old binaries).
  - _Firezone_: a certificate from the account's Firezone device CA. It
    proves the device holds the key it got its certificate for. A hardware
    key is a detail on it once hardware attestation proves it (I.12), not
    a separate state.
  - _Organization_: a certificate that chains to one of the account's trust
    anchors (MDM).

  The Firezone device CA is itself a trust anchor, marked `system`
  (#16855): it shows in the Trust Anchors list, nobody edits or deletes
  it, and its key stays in `device_certificate_authorities`. Everything
  that means the organization's own PKI leaves `system` anchors out.

  Verified follows the key: it stays through renewal, a CA rotation and the
  first claim of a row without a key, and is cleared when the key is
  replaced (reset identity, ephemeral takeover). Existing code keeps its
  names for the MDM case (`device_attested`, `last_attested_*`).

- **Ephemeral devices** keep a random key in memory only and enroll again
  at every start. A device is ephemeral when it cannot write its state
  directory, or when `FIREZONE_ID` is set (its identity is then its
  configuration, which covers CI runners whose disk is wiped between
  jobs). `FIREZONE_EPHEMERAL=true` or `false` overrides both. The portal
  stores this as `ephemeral` on the row. The device reports it and the
  portal cannot check it, so it never grants access: it only lets a later
  enrollment take the row over (claim rules), and only the row's own
  enrollment can set it. It is internal for now: not in the admin UI, the
  REST API or exports.
- **No certificate list.** The device row stores the SHA-256 of the
  device's public key. A certificate is valid only while its key matches
  the row, so deleting the device or resetting its identity ends every
  certificate for it. The portal keeps no CRL of its own certificates.
- **`type` does not change in this phase.** An enrolled Client stays
  `client` and an enrolled Gateway stays `gateway`. The `type = NULL` switch
  comes with the unified binary.

**Enrollment.** Every connection from 1.6.0 Clients and 1.6.6 Gateways is
mTLS, so a device gets its certificate before it opens a socket:
`POST /device/certificate` on the API host, without mTLS. The device sends
its token and a CSR for its key, and gets back a 90-day certificate and the
CA certificate. The request touches no device row: the certificate names
the key, not a device, and the key binds to a row only at connect (claim
rules below). A certificate grants nothing by itself, because every connect
still needs a valid token. The device calls it:

1. When it has no certificate (a new install, an upgrade, a wiped state
   directory, or an ephemeral start).
2. For renewal: a CSR for the same key at a random point between 55% and
   70% of the lifetime.
3. When the portal refused its certificate (the device was deleted, its
   identity was reset, its CA was rotated, or the certificate expired).

The endpoint is rate limited per token and per account, because every
call is a Key Vault signature and the vault's limit is shared by the whole
region. A Key Vault 429 becomes a 429 and any other vault failure a 503,
both with `Retry-After`. Old binaries keep connecting without mTLS, as
today.

**Managed devices.** A device uses its MDM identity when it has one (on
Apple, the `identityReference` of the managed VPN profile, which the client
already reads), and its Firezone identity otherwise. One TLS handshake
carries one client certificate, so it shows only one of them.

- A device usually enrolls with Firezone first and becomes managed later.
  On its first connect with the MDM certificate, it also sends its Firezone
  certificate and a signature with its Firezone key over the SHA-256 of the
  MDM certificate. The portal checks the key against the row and records the
  MDM device id on that row. The signature is useless with any other MDM
  certificate, so it needs no nonce.
- The client keeps its Firezone key while it is managed, and renews the
  Firezone certificate in the background with a separate request, at the
  same random point. When the MDM certificate is removed or the device leaves
  management, the client falls back to the Firezone certificate and lands
  on the same row.
- Device trust Organization holds only while the device connects with a
  valid MDM certificate. On the Firezone fallback it is the same device
  with device trust Firezone.
- An MDM identity is used only when its certificate carries an MDM device
  id. Without one, the portal can find the row only by issuer and serial,
  and every MDM renewal would make a new row, so the device keeps its
  Firezone identity.

**Claim rules.** The first connect with a certificate decides which row its
key gets: the row that already has the key; otherwise the row with the
reported `firezone_id` and no key; otherwise a new row. The first device to
connect with a `firezone_id` wins:

- The key claims the row with the reported `firezone_id` that has no key
  yet: for a Gateway on a Site token, only in that Site; for a Gateway on a
  device-bound token, the bound row; for a Client, the actor's rows. The
  claim stores the key hash. The row keeps its `firezone_id` as a label,
  but the `firezone_id` lookup on connect skips rows with a key, so the id
  alone never reaches a claimed row.
- Only rows without a key need a unique `firezone_id`. The Gateway index
  becomes `type = 'gateway' AND key_hash IS NULL AND NOT
firezone_id_exempt`, so keyed rows can share an id.
- A later enrollment with the same `firezone_id` gets a new row. This covers
  the Gateway clones that share an id across Sites.
- The key belongs to the machine, not to the user, so everyone who signs in
  on that machine uses the same key and row.
- A row that already has a key cannot be claimed again. Only the old key
  (renewal) or an admin reset can replace it. The one exception is an
  ephemeral row: an ephemeral enrollment takes over an ephemeral row with
  the same `firezone_id` in the same scope (as above) when that row is
  offline. If the row is online, the enrollment gets 409 and retries. An
  ephemeral row never proved more than its token, so this is no weaker.
- One live connection per row with a key, for Clients and Gateways alike.
  The first connection wins and the second gets 409; this covers a copy
  with the same key and a reconnect while the old socket still looks live.
  A device that gets 409 retries with backoff. Rows without a key keep
  today's behavior (Clients: the newest connection wins; Gateways: 409),
  so old binaries see no change.
- A claim never moves a row between Sites. The legacy move between Sites
  stays only for rows without a key, and goes away with Site tokens.
- Copies of a machine made after it enrolled (a VM image, a copied state
  directory or vTPM) share its key and so its row. The portal refuses a
  second live connection with the same key, and the device logs that its
  identity is in use by another machine. The fix is to clear the state
  directory on the copy, or to build images before the first start.
- A row keeps its key when its token changes. A Gateway host that moves to
  a service account token keeps its row once the unified binary can carry
  it.

**Connect.** A new release connects to `/client` or `/gateway` on the mTLS
host with its certificate. The socket checks the certificate against the
account's CA and the key hash on the row, finds the row from the
certificate, and then checks the token as today. A row with a key is never
found by `firezone_id`, so an old release or a forged id cannot land on it.
A release without identity connects as today, on the API host, and is found
by `firezone_id` among rows without a key.

**Containers.** mTLS is not required for them. A container without a
volume cannot keep a key, so the container images do not enroll by default.
They connect with their token and a stable `FIREZONE_ID` as today, and the
portal finds them by `firezone_id` among rows without a key, and for a
Gateway only in its own Site. An operator who mounts a volume can turn
enrollment on.

**Policies.** Two settings. "Verified device", as today. "Device trust"
(`device_trust`, #16854, which replaced `require_attestation`): `none`,
`firezone` (Firezone or Organization; added with I.6), or `organization`.
After I.12 a "Require a hardware key" checkbox joins it.

**`/device/v1` until the unification.** It is on `main` but no release uses
it. It is turned off until the unified binary ships. Then it requires a
certificate from every device that can keep a key, and accepts a container
without one on the same terms as the legacy sockets.

**Steps.** Portal, one PR per deploy:

- I.1 Device CA per account (#16722, P-256 in #16829): `DEVICE_CA_KEY_STORAGE` is `db` or
  `azure`, a periodic job backfills every account without a CA (disabled or
  not), and the CA shows read only on the Trust Anchors page for every
  account, with the versions that use it for mTLS (Clients 1.6.0, Gateways
  1.6.6). Done and in production.
  Infra first: a Key Vault Standard per region and the "Key Vault Crypto
  Officer" role for the portal identity.
- `/device/v1` is separate work and not a step here: device identity
  ships on `/client` and `/gateway`.
- I.4 Device key columns on `devices`: key hash and `ephemeral`, and the
  Client and Gateway `firezone_id` unique indexes limited to rows without
  a key (#16848). No "enrolled by" column: most devices have one actor, so
  the `device_actors` row with the earliest `first_seen_at` stands in for
  the enroller. If a feature needs the exact enroller, it becomes
  `devices.enrolled_by_actor_id` and `enrolled_at`: one current key per
  device, and Gateways have no `device_actors` rows. No foreign key: the id
  stays after the actor is deleted, and the panel shows "Enrolled by a
  deleted user".
- I.5 Certificate issuance in `Portal.DeviceCA` (#16849, done), then
  `POST /device/certificate` (#16853) on the API host: token and CSR in,
  certificate out, rate limited per token and per account, 429 or 503 with
  `Retry-After`.
- I.6 Connect with the certificate on `/client` and `/gateway`, on the mTLS
  host: the key hash comes from the TLS certificate and the claim rules
  (including the ephemeral takeover) run in the existing connect path.
  The `firezone_id` lookup skips rows with a key. One live connection per
  keyed row for Clients and Gateways, first wins, 409 `device_key_in_use`
  for the second, so the device can log that a copy uses its identity. A
  managed device connects with its MDM certificate instead and binds its
  Firezone key to the same row (Managed devices above); the row then holds
  both `key_hash` and the `last_attested_*` identity.
- I.7 Reset identity on the device panel, and the key cleared when a device
  is deleted.
- I.7b Internal CA rotation, ops only (in `portal-ops`): rotate one
  account, rotate every account as paced jobs (key creation is the limit),
  and the emergency variant that also disconnects the account's devices.
  Do not rotate just before a deploy: a deploy reconnects every device at
  once.
- I.8 The `firezone` value of `device_trust`, offered once I.6 ships.

Rust and the apps:

- I.9 Software key, CSR, enroll and renewal in the shared client and Gateway
  code, and the certificate in the connect handshake. Renewal at a random
  point of the lifetime, exponential backoff with jitter on 429, and the
  working certificate kept until the new one is stored. Ephemeral mode
  (in-memory key) when the state directory is not writable or
  `FIREZONE_ID` is set, with `FIREZONE_EPHEMERAL` to override.
- I.10 Gateway release with identity: 1.6.6.
- I.10b Remove `firezone_id_exempt` once every exempt row has a key or is
  deleted (17 `firezone_id` groups on 2026-11-27, 4 with all clones
  online). Delete exempt rows still without a key by then; those Gateways
  get 409 until they upgrade. Then drop the flag from the index.
- I.11 Client releases with identity, 1.6.0: Apple (the device trust signing path
  through Swift already exists), Android, Windows and Linux GUI, headless.
- I.12 Hardware keys per platform, one release each, with hardware key
  attestation checked when the device gets its certificate, and the
  "Require a hardware key" checkbox.

**Open.**

- Gateways that today reach only `api.firezone.dev` must also reach the mTLS
  host. Customers with strict egress rules have to allow it. The other
  choice is optional client certificates on the API host.
- A reinstalled mobile app may keep its `firezone_id` but not its key. It
  then gets a new row until an admin resets the old one.

### Phase 0: prep, no behaviour change

- **0.1 Audit: duplicate `firezone_id`.** Done 2026-10-22; figures kept privately. Read-only query listing devices that
  share `(account_id, firezone_id)` across actors or sites, and attested rows
  sharing `(issuer, serial)`. Output drives 2.15.
- **0.2 Audit: multi-owner tokens in use.** Done 2026-10-22; figures kept privately. Devices whose `gateway_token_id`
  points at a token with `site_id` set, per account. Drives the auto-join
  support in 1.4 and the comms plan.
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
  `client/channel/shared.ex`. Existing channel tests unchanged. Done:
  `Portal.Routing.select_receiver/3` picks from the gateways online in the
  resource's site.
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

Gateway tokens move first, into a new `device_tokens` table owned by the
legacy Gateway actor (decision 7). Client tokens follow the same steps once
the Gateway move is complete. There are no triggers: the app writes both
tables, and a migration in the next deploy copies what is missing.

- **1.1 Code and migration: actor type `legacy_gateway`.** Every allow-list
  on actor type leaves it out; `Safe` hides it from scoped actor queries and
  refuses every action for it. Done (#16347).
- **1.2 Migration and code: `device_tokens` and dual write.** Same ids and
  secret columns as `gateway_tokens`, plus `actor_id`, `auth_provider_id` and
  `expires_at`. A temporary foreign key to `gateway_tokens` (cascade) removes
  a copy whenever its Gateway token is deleted. Token creation and rotation
  write both tables in one transaction and create the account's legacy
  Gateway actor when it is missing. Done (#16348).
- **1.3 Migration: copy existing Gateway tokens.** Creates the missing legacy
  Gateway actors, syncs rotation stamps and copies missing tokens. The audit
  log redacts `device_tokens` secrets from this deploy on, one deploy before
  the table is published. Done (#16357).
- **1.4 Code: Gateway tokens read from `device_tokens`.** Verification, the
  rotated sibling, Site token lists, REST reads and the grace reaper read the
  copy. Every revoke deletes from both tables in one transaction, so nothing
  depends on the cascade from here. Depends 1.3. (#16369)
- **1.5 Code: the Gateway socket builds a Subject.** Verification loads the
  token's actor in the same query. A new `Credential.GatewayToken` carries no
  scopes and no auth provider, and the subject has no expiry, because
  Gateway tokens never expire. The socket assigns `subject`. The session log
  subject keeps its current shape. Depends 1.4. Done (#16375).
- **1.6 Code: Gateway writes scoped.** The `Safe.unscoped` calls in the
  Gateway socket and channel become `Safe.scoped(subject)`. `Safe.permit`
  grants the legacy Gateway actor only what the socket does: insert and
  update its device and write its `site_devices` row. It writes no tokens:
  rotation is an admin action, and confirming a rotation happens during
  verification, before there is a subject. Everything else stays refused. Audit entries for
  these writes then show the actor. Old and new nodes write the same rows,
  so there is no rollout order. Depends 1.5. Done (#16376).
- **1.7 Stop writing `gateway_tokens`.** One deploy, after 1.4 runs on every
  node. The migration drops the temporary foreign key and points
  `devices.gateway_token_id` at `device_tokens` (NOT VALID, with a
  `lock_timeout`). Replication publishes `device_tokens` instead of
  `gateway_tokens`, so the revoke disconnect comes from `device_tokens`.
  Token creation and rotation write only `device_tokens`, and the session
  flush checks tokens in `device_tokens`. Depends 1.4 deployed. Done
  (#16372).
- **1.8 Migration: validate the `devices` foreign key.** Depends 1.7
  deployed. Done (#16372).
- **1.9 Migration (contract): drop `gateway_tokens`, `Portal.GatewayToken`
  and `Hooks.GatewayTokens`.** Depends 1.7 deployed. Two deploys, because
  1.7 nodes still delete `gateway_tokens` rows on revoke: first no code
  touches the table (#16377), then the table is dropped (#16378). Done.
- **1.10 Removed.** No free service account: Gateways stay with the legacy
  Gateway actor (decision 8).
- **1.11 Client tokens into `device_tokens`.** Done (#16392 to #16398; the
  device token columns became `devices.token_id` in #16462 to #16468). The
  same steps as 1.2 to 1.4, 1.7 and 1.9, after 1.7, one PR per deploy:

  - C1: create and revoke write both tables in one transaction. The
    `device_tokens` actor foreign key becomes `ON DELETE CASCADE`, as on
    `client_tokens`. `/client` and `/gateway` accept the `"device"` salt;
    nothing signs with it yet.
  - C2: copy missing client tokens, and delete copies whose original was
    revoked by a C0 node during the C1 rollout.
  - C3: verification, REST and UI read client tokens from `device_tokens`,
    with the shape rules of decision 11.
  - C4: stop writing `client_tokens`. New tokens are signed with `"device"`.
    `policy_authorizations.token_id` and `devices.client_token_id` point at
    `device_tokens` (NOT VALID, one table per migration, short
    `lock_timeout`). Replication publishes `device_tokens` instead of
    `client_tokens`.
  - C5: validate both foreign keys.
  - C6a: no code touches `client_tokens`. C6b: drop it.

  Ids are kept, so stored REST ids still work.
  `policy_authorizations.token_id` points at `device_tokens` only after
  every node writes both tables. The `Safe` grants on `DeviceToken` already
  match the client token grants. New tokens are signed with `"device"`, and
  `/client` and `/gateway` check the row shape in their lookup (decision
  11). The `device_tokens` change hook broadcasts every insert and delete;
  the pages that listen show one actor's tokens, so Gateway tokens, owned by
  the legacy Gateway actor, reach no page. `devices.client_token_id` and
  `devices.gateway_token_id` collapse into `token_id`.

- **1.12 Code: `Devices.provision_device/4`.** Generalizes
  `provision_gateway`: inserts a device and mints a device-bound token for
  the actor given. The deploy UI calls it with the legacy Gateway actor until
  `/device/v1` ships. Depends 1.7.
- **1.13 REST: token endpoints on `device_tokens`.** The existing Gateway and
  client token endpoints and scopes stay, same ids and JSON, and each returns
  exactly its old token set, so an old scope never widens. Each endpoint
  filters by the row shape of decision 11: Gateway token endpoints by Site
  or by a Gateway device in it, client token endpoints by actor with no Site
  and no Gateway device. New `POST
/devices/:id/token`. OpenAPI. The API surface is renamed to device tokens
  at the final collapse, with the old paths and scopes kept as aliases.
  Depends 1.12.
- **1.14 UI: tokens tab** on service accounts shows device-bound tokens with
  their device; rotate available for any device-bound token. Depends 1.7.
- **1.15 Removed.** No "Move to service account" (decision 8).

### Phase 2: device rows and site assignment

The UI steps in this phase (2.12, 2.19 to 2.21) ship behind an account
feature flag, `unified_devices`, and are switched on for everyone at the
cutover in 3.8b, so admins see the new package and the new screens on the
same day.

- **2.1 Migration: `device_actors`.** `(account_id, device_id, actor_id,
first_seen_at, last_seen_at)`, PK on the three ids, cascading FKs. Ecto
  schema; both replication consumer lists; broadcast-only hook. Shipped
  with 2.3 in #16469.
- **2.2 Migration: backfill `device_actors`** from `devices.actor_id` for
  client rows. Depends 2.1. Shipped in #16470.
- **2.3 Code: client connect upserts `device_actors`** through the session
  flush queue. Depends 2.1. Shipped in #16469.
- **2.4 Code: pool criteria read `device_actors`.** Own-devices and
  actor-group SQL use EXISTS on the new table; presence-based `member?`
  unchanged. Criteria tests. Depends 2.2. Shipped in #16563. Known edge
  case: the presence check for an online target uses the actor connected on
  it, while the SQL check counts every actor that has used it. A device that
  several people use can be in a pool while offline and out of it while
  online. Kept as is, since most organizations have one user per device.
- **2.5 Code: seats from `device_actors.last_seen_at`.** Billing tests.
  Depends 2.2. Shipped in #16473. The unit stays one seat per actor.
- **2.6 UI: Devices "Owner" becomes "Users"**; actor detail lists devices via
  `device_actors`; actor delete hook disconnects that actor's sessions.
  Depends 2.2. Partly shipped in #16563: the device pages, pool member lists
  and REST show the actor that connected last. With one user per device,
  the common case, that actor is the owner, so the "Owner" label stays. The
  "Users" list is not built.
- **2.6b Code: the connected actor comes from the token.** The client
  socket, channel, presence and cache use the actor of the token that
  connected, held on the socket, and never read `devices.actor_id`.
  Depends 2.3. Shipped in #16563, which also writes the `device_actors` row
  when a device is created, so a new device has a user before its first
  session flush.
- **2.6c Migration: deleting an actor keeps its devices.** The devices
  `actor_id` FK becomes `ON DELETE SET NULL`; `device_type_client_fields`
  is dropped and `actor_id` becomes nullable. Only the actor's
  `device_actors` rows go. A device with no users stays, because flow logs
  and other records refer to it; a later sweep can delete such devices.
  Depends 2.6, 2.6b. Shipped in #16566. The REST API shows the nil UUID as
  the `actor_id` of a Client with no users, so the field stays a non-null
  UUID, and filtering by the nil UUID lists those Clients.
- **2.7 Migration: `site_devices`.** `(account_id, site_id, device_id,
inserted_at)`, unique on the three ids, cascading FKs. Ecto schema, `Site`
  associations, consumer lists, hook that broadcasts to the site topic.
  Shipped. A device holds one site for now (#16288).
- **2.8 Migration: backfill `site_devices`** from `devices.site_id`.
  Depends 2.7. Shipped in #16286.
- **2.9 Migration: trigger mirroring `devices.site_id` writes** into
  `site_devices` for one release, so unconverted write paths stay
  correct. Depends 2.8. Not needed: reads moved to `site_devices` (#16290,
  #16336), writes stopped (#16332) and the column was dropped (#16337).
- **2.10 Code: presence meta `site_ids`** from `site_devices` at connect; the
  per-site presence lookups read it. Depends 2.8. Partly shipped: presence
  carries the device's one `site_id` from `site_devices`. It becomes a list
  when a device can serve several sites.
- **2.11 Code: `Routing.select_receiver` uses `site_devices`.** Candidates are
  online devices whose `site_ids` include the resource's site, never the
  initiator itself, still limited to `type == :gateway` until 4.6. The
  client's connectable resources exclude any resource served by a site the
  device is assigned to. Depends 0.6, 2.10. Partly shipped: the receiver is
  picked from the gateways online in the resource's site.
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
  Depends 2.8. Not done: `site_devices` rows go with the site, but deleting
  a site still deletes its gateways.
- **2.14 REST: `/sites/:id/gateways` reads `site_devices`; new `POST` and
  `DELETE /sites/:id/devices`.** Depends 2.8.
- **2.15 Migration: merge duplicate device rows.** Dry-run mode first. For
  each identity group from 0.1 keep the most recently seen row, falling back to `inserted_at` where
  `last_seen_at` is null; move
  `device_actors`, both sides of `policy_authorizations`, `site_devices`, listed
  pool ids (jsonb), posture rows; delete the rest. Announce slug changes.
  Depends 0.1, 2.2, 2.8. The Client part shipped in #16565: rows sharing a
  `firezone_id` merge into the most recently seen one, which takes their
  `device_actors` rows, device-bound tokens and listed pool ids. Their
  policy authorizations are deleted with them, and a connected duplicate
  reconnects onto the kept row. No Client shared a certificate or MDM id
  across actors in either region, so nothing was merged on those.
- **2.16 Migration: identity uniqueness without actor.** Unique `(account_id,
firezone_id) WHERE firezone_id IS NOT NULL` and `(account_id, issuer,
serial)`; drop the actor-scoped indexes. Depends 2.15. The Gateway part
  shipped in #16560: Gateways that already shared a `firezone_id` across
  Sites are flagged `firezone_id_exempt` and left out of the index until
  their admins clean them up, and the actor-scoped `firezone_id` index now
  covers Clients only. The Client part shipped in #16565 (`firezone_id`) and
  #16566 (certificate and MDM id).
- **2.17 Code: lookups without actor.** Client socket `find_by_firezone_id`
  by account; attested lookup in `device_trust.ex` by account; `Device`
  changeset validations by presence of fields rather than `type`. Depends
  2.16. The lookups shipped in #16564. The changeset part is not done.
- **2.18 Code: evaluator accepts any device.** `Policies.Evaluator`,
  `Condition`, `Postures.Evaluator` drop the `type: :client` guards; the
  session actor is passed explicitly. Depends 2.17.
- **2.19 UI: Devices page lists every device** with "Routes for"
  from `site_devices` and the two filters. Depends 2.10.
- **2.20 UI: device detail** with the "Routes traffic for" sites editor, users, pools, token
  rotate. Depends 2.12, 1.14.
- **2.21 UI: Add device wizard** replaces Deploy gateway on Sites and Devices,
  calling `provision_device`, deploy tabs reused, sites multi-select writes
  `site_devices`. Depends 1.12, 2.12.
- **2.22 Code: `devices.type` stays maintained** as a legacy value (gateway
  when provisioned to serve a site, client otherwise) for `/clients`,
  component versions and protocol selection until phase 6. No PR of its own;
  a rule each step above respects.
- **2.23 Code: the outdated-gateway email selects by site assignment.** The
  weekly email to admins keeps its meaning, "the device in front of your
  site is behind and some clients cannot connect", so it covers every
  device with a `site_devices` row that runs the Linux daemon: the gateways
  as today, plus a Linux desktop or headless box an admin adds to a site.
  Each device is compared against the release line of the component it
  reports, so a `firezone` binary is not held to the Gateway's numbers.
  Desktops and phones in a site are left to the fleet report below.
  Depends 2.8.
- **2.24 Later: a weekly fleet report.** One email per account to admins
  with the preference on, only in weeks where something is behind: devices
  grouped by component with a count per version, and a section for the
  devices below the floor the compatibility window will drop at the next
  release, with the date. Its own last-sent timestamp and preference key.
  The upgrade asks of 0.9 and the targeted email of 5.12 become its first
  issues rather than campaigns of their own. Not before phase 3.

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
  reproduces today's rules exactly. The portal stores a declared range as
  is (decision 10). Compatible means the ranges overlap.
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
- **5b.7 Apple: macOS and iOS serve.** The Network Extension runs
  `DeviceState` over `/device/v1` with the userspace forwarder only. A
  manual test adds a served resource and pings it through a second device.
  Depends 5b.4.
- **5b.8 Android serves.** `DeviceState` over `/device/v1` with the
  userspace forwarder only. Every host socket of the forwarder goes through
  `VpnService.protect()`, so it leaves outside the tunnel. Same manual test
  as 5b.7. Depends 5b.4.
- **5b.9 Integration tests: both forwarders** on the one image from 5.10,
  the Linux container once with and once without `NET_ADMIN`, with ping,
  TCP and UDP downloads. Depends 5b.2, 5b.4.
- **5b.10 Portal and docs.** Device detail shows the forwarder in use; the
  0.8 page gains the Linux `--no-kernel-forwarding` flag and says that
  Windows, macOS, iOS and Android use the userspace forwarder only.
  Depends 5b.1.

### Phase 6: contract

- **6.1 REST: `/devices`.** Lists every row, legacy records included, with
  `type` shown as legacy (`client`, `gateway` or null). `/clients` and
  `/sites/:id/gateways` stay unchanged and return only legacy records, so a
  record leaves them when its host upgrades and keeps its id under
  `/devices`. Site assignment through `/sites/:id/devices` (2.14). Ships last.
- **6.2 Code: component and version logic by user agent only.** Depends 3.8.
- **6.3 Code: pool criteria and pickers accept legacy client records and
  devices (`type IS NULL`); pools never target legacy gateway records.** Done
  early, with `last_seen_device_v1` removed. UI and REST say "1.7.0 or later".
- **6.4 Migration: drop `devices.type`** when no legacy records remain, not on
  a fixed date. Depends 6.1, 6.2, 6.3.
- **6.5 Migration: drop `devices.site_id` and its trigger, drop
  `devices.actor_id`.** Depends 2.9 and 2.17 deployed, and no code reads
  `devices.actor_id`: lists, pools, hooks and billing read `device_actors`
  (2.4 to 2.6), the connected actor comes from the token (2.6b) and lookups
  go by account (2.17). `devices.actor_id` was dropped early: #16567 stopped
  reading and writing it, and #16569 dropped the column. `devices.site_id`
  was dropped in #16337, without the trigger of 2.9.
- **6.6 Code and migration: Internet Site becomes a normal site.** Flip
  `managed_by`, drop the pairing validation and the pinned row; Internet
  resource gets a site selector. Depends 0.4 in the fleet, 5.11.
- **6.7 UI: wording sweep.** "Gateway" becomes "device" wherever it means
  the machine; nav and page copy. Depends 2.21.
- **6.8 Remove legacy socket adapters** after the compat window. Separate
  decision, far later.
- **6.9 Code: role names in internal code.** A device is what a thing is.
  Its role in one connection is "initiator" or "receiver", the same words as
  the `initiating_device_id` and `receiving_device_id` columns and
  `Routing.select_receiver`. Internal code that says "client" or "gateway" for
  a role changes to these words, for example `PolicyAuthorization`'s `:client`
  and `:gateway` associations, `Cache.Client` and `Cache.Gateway`, and
  `connected_gateways_in_site`. "Responder" stays a flow log word: the side
  that answers a network flow, which is not always the receiver of the
  authorization. The legacy sockets and their wire fields (`client_id`,
  `gateway_id`), the REST paths and the `type` enum keep their names. These are
  renames only, with no change between nodes, so they ship in any deploy. Do
  them in one pass after the feature work and before 6.4, so they do not
  conflict with open feature PRs.

## 3a. Deploy points and releases

The portal deploys on every merge. These are the points where order matters.

| Point | Must be live                               | Release                                                                                   |
| ----- | ------------------------------------------ | ----------------------------------------------------------------------------------------- |
| DI    | I.1 to I.8                                 | RI: Client and Gateway releases with device identity (I.10, I.11), before every R below   |
| D1    | 0.6, 0.7                                   | R1: the next gateway release (1.6.6) with 0.4 and 0.5                                     |
| D2    | 1.1 to 1.7, 1.12 to 1.14                   | none                                                                                      |
| D3    | 1.8, 1.9, 1.11, after D2 settled           | none                                                                                      |
| D4    | 2.1 to 2.21                                | none                                                                                      |
| D5    | 3.0, 3.8, RI in the fleet                  | R2: `firezone` 1.7.0 over `/device/v1` with its certificate; `unified_devices` on for all |
| D6    | 4.1 to 4.13                                | R3: `firezone` 1.8.0 on `DeviceState` over `/device/v1`                                   |
| D7    | 5.11 after R3 is in the fleet              | cutover 5.12                                                                              |
| D8    | 6.1 to 6.7 after 2.9 and 2.17 settled      | R4: `firezone` minor dropping alias bins (3.10)                                           |
| D9    | 6.8 once 0.9 has cleared the old protocols | none                                                                                      |

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
| Gateway 1.6.6 (R1)  | 1.5, 1.6, 1.7  | n/a                      | n/a                              |
| `firezone` 1.7 (R2) | 1.5, 1.6, 1.7  | 1.5, 1.6, `firezone` 1.7 | Clients 1.5, 1.6, `firezone` 1.7 |
| `firezone` 1.8 (R3) | 1.6, 1.7, 1.8  | 1.6, `firezone` 1.7, 1.8 | Clients 1.6, `firezone` 1.7, 1.8 |

The Windows GUI needs no release. Apple and Android release once, to serve
(5b.7, 5b.8). PR count is about 96 code PRs plus 3 docs PRs before merging
small neighbours: phase 0 has 4, phase 1 has 15, phase 2 has 24, phase 3
has 12, phase 4 has 13, phase 5 has 12, phase 5b has 10, phase 6 has 8.

## 3b. Notes for customer communication

Changes customers must hear about when the unified binary ships to gateway
hosts. Collect them here and use them for the release notes and the email.

- **DNS for the resources a device serves.** A device always resolves the
  DNS resources it serves with the host's own DNS servers, as gateways do
  today. The account's DNS settings never change this. A gateway host that
  switches to the new `firezone` binary keeps resolving resources the same
  way. If the host's DNS servers change, for example after a network change,
  the device uses the new ones without a restart.
- **DNS for the device's own lookups.** A device that only serves, such as a
  host that connects with a gateway token, does not take over the host's DNS.
  When a host connects with a user or service account token, it also
  initiates connections. It then takes over the host's DNS like every client,
  and its own lookups follow the account's DNS settings: upstream resolvers
  and search domain.
- **REST after an upgrade.** When a host upgrades to 1.7, its record leaves
  `/clients` or `/sites/{id}/gateways` and shows under `/devices` with the
  same id. `/devices` lists every device, old and new, so scripts can move to
  it at any time.

## 4. Decisions taken

1. **Daemon user on Linux:** the `firezone` user with `CAP_NET_ADMIN`, polkit
   rule for systemd-resolved, `resolv.conf` control documented as root-only.
2. **Billing:** customer service accounts that own routing devices count as
   any actor does today. The legacy Gateway actor (decision 7) never counts.
3. **Binary shape:** one executable, `firezone`, with `run` as the daemon.
4. **Site assignment:** explicit rows only; rules not planned.
5. **Forwarding:** on Linux the daemon owns kernel forwarding (sysctls and
   an nftables table it creates), enabled only once it has a resource to
   serve, with `--no-kernel-forwarding` as the opt-out; everywhere else, and
   as the Linux fallback, a userspace forwarder in smoltcp with ICMP echo
   through the platform ping APIs. Windows serves through userspace only.

6. **One credential per device.** A device holds one token. There is no
   device token with a user sign-in on top. The token's actor decides the
   device's policies, and the token's lifetime decides how long it stays
   connected. A user's laptop serves a Site only while that user is signed
   in; always-on infrastructure is deployed with a non-user token.
7. **Legacy Gateway actor.** Each account gets one actor of a new type,
   `legacy_gateway`, that owns the existing Gateway tokens. "Legacy"
   describes the credential, not the binary: a Gateway upgraded to the new
   binary keeps its token and this owner. Admins never see the actor; the
   Site's token list stays as today. Because it is a new type, every
   allow-list on actor type leaves it out by default: it takes no seat, is not a user or a service account for
   any limit, is not in Everyone, cannot be added to groups, has no
   policies, cannot be edited, disabled or deleted, and no token can be
   minted for it. Its tokens never expire (deployed Gateways exit and stay
   down on any disconnect); rotation and revocation are the controls. Once
   `/device/v1` ships, no new tokens are minted for it, but existing ones
   keep working on both `/gateway` and `/device/v1`, and rotating one keeps
   the owner. The narrow name keeps it from being reused for anything else.
   The type stays as long as any legacy Gateway token exists.
8. **A Gateway gets outbound access only through a service account.** A
   device whose token the legacy Gateway actor owns can only serve, for as
   long as it keeps that token. Tokens never change owner. To let a Gateway
   reach other devices or resources, the admin creates a service account,
   which takes a seat, and gives the host a new token for it. The device row
   and its Sites stay only once device identity no longer depends on the
   owner (2.15); before that, the admin adds the device to its Sites again.
9. **Upgrading never needs a new token.** Existing Gateways upgrade the
   package or image and keep their token, `FIREZONE_ID`, device row and
   Site. Rolling back to the old binary keeps working because `/gateway`
   stays served. Retiring `/gateway` later only asks for a binary upgrade.
10. **Version compatibility by minor range, declared by the device.** Each device has a range of minors it is
    compatible with. New binaries send it as `proto_min` and `proto_max`
    connect parameters, so a release can narrow its own range without a
    portal change; `firezone` declares `[m-2, m]`. Devices that send no range
    get one from the version they report: a legacy Client on minor `m` is
    `[m, m]` and a legacy Gateway is `[m-1, m+1]`. There is no portal floor,
    as there is none today; if a release ever declares a range it cannot
    support, a clamp at connect is one portal PR. Two devices are compatible when
    their ranges overlap, which reproduces today's rules for legacy devices.
    The pair
    speaks the highest minor both share, sent with the connection details.
    Message shapes change only with a new socket version, and optional
    abilities are capabilities in presence; capabilities only decide what the
    portal sends, never what a device may do. A minimum supported minor can
    refuse `/device/v1` binaries at connect; legacy sockets are not refused,
    since a refused Gateway stays down.
11. **One kind of token.** `device_tokens` has no `type` column. Every new
    token is signed with the `"device"` salt; `"client"` and `"gateway"`
    remain as fallbacks for older tokens. The legacy sockets and the REST
    endpoints tell client and Gateway tokens apart by the row's shape (Site,
    bound device and its type), which the lookup query enforces. Upgrading
    to `/device/v1` never needs a new token: it accepts every salt and every
    shape, and serving a Site comes from `site_devices`, not the token.

12. **Device identity before the unification (2026-11-22).** The token says
    who acts and a portal-issued certificate says which machine connects.
    Phase I ships it on `/client` and `/gateway` first: one CA per account
    (P-256 in Key Vault Standard, or in the database without Key Vault), 90-day certificates, the device trust host for mTLS,
    hardware keys where the platform has them. A row with a key is found
    only by its certificate.

## 5. Risks

- Phase I: Gateways must reach the mTLS host, and devices that lose their
  key (containers without a volume, reinstalled apps) get a new row. See
  the open items in Phase I.
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
| I     | 12    | large     |
| 0     | 9     | small     |
| 1     | 15    | medium    |
| 2     | 25    | medium    |
| 2b    | 1     | docs only |
| 3     | 13    | medium    |
| 4     | 13    | large     |
| 5     | 12    | large     |
| 5b    | 10    | medium    |
| 6     | 8     | medium    |
