# Completion packet I/O prototype

The existing Rust client event loop still owns WireGuard, ICE, DNS, portal updates,
timers, GSO reservations, and shutdown. Its packet transport is pluggable:

| Platform | Packet I/O | State executor |
| --- | --- | --- |
| Linux | Compio `io_uring`, UDP GSO/GRO, offloaded TUN | One current-thread executor |
| Windows | Compio IOCP, UDP USO/URO, Wintun event/rings | One current-thread executor |
| macOS/iOS | Network.framework UDP, `NEPacketTunnelFlow` | Serial Swift dispatch queue driving Rust |
| Android | Existing protected socket/TUN transport | Existing client runtime |

Apple does not link Compio. Android also has a Compio polling adapter for a plain
TUN descriptor, but the Android app uses its existing `VpnService` protection path.

## Native client

Build from the Rust workspace:

```sh
cargo build -p completion-io --features native-client --example client
```

Run the resulting `target/debug/examples/client` with administrative privileges,
feeding a JSON configuration on stdin. It creates the managed Firezone TUN device
and uses the existing route and DNS managers. Do not run alongside another Firezone
client. Configuration fields are `api_url`, `token`, `device_id`, optional
`device_name`, `internet_resource_active`, and `dns_servers`. Keep credentials in
private input, outside the repository.

`FIREZONE_COMPLETION_CORE` optionally pins the state/crypto thread to a core.
`FIREZONE_DNS_CONTROL` accepts the existing platform DNS control methods.
SIGINT/SIGTERM/Ctrl+C drain output completions; SIGHUP and network notifications
reset the shared state and rebind the UDP sockets. Windows uses the existing
verified Wintun DLL installation and ring sizing.

## Apple client

Set the tunnel profile's provider configuration `completion_io` to `true`, then
build the Apple app with its normal build tasks. The existing UniFFI generation
task generates `CompletionConfig`, `CompletionControl`, and typed `Event` bindings.
TLS identities use the existing `ClientTlsIdentity` interface.

The constructor transfers a local packet driver to Swift. The adapter owns that
driver on its serial queue and frees it exactly once after shutdown. UniFFI carries
commands and events, while the [small packet ABI](../../../client-ffi/include/completion.h)
borrows buffers without converting payloads to UniFFI byte vectors. The local Rust
future and `Rc` queues are not exposed as `Send + Sync` UniFFI objects.

Packet completions pump the Rust driver immediately. A 10 ms timer services the
existing Tokio portal/DNS reactor and state timers. This prototype has not moved
the portal or DNS transports into Network.framework. Apple TUN writes use
`NEPacketTunnelFlow.writePackets`, which has no completion callback.

## Ownership and ordering

- A receive buffer belongs to the backend until it is transferred to Rust.
  Rust retains foreign UDP storage until all datagrams in it have been processed.
- An output operation owns its buffer. The backend acknowledges its operation ID
  exactly once when I/O completes or is cancelled.
- Acknowledgement releases backpressure. Buffer storage is released separately,
  because a framework can retain it past its completion callback.
- Each UDP socket and TUN writer submits in order. GSO fallback sends owned slices
  sequentially. Independent UDP flows can complete in different orders.
- Reset changes the generation. Stale receive callbacks and completion failures
  do not enter the new state. Existing output storage remains valid until released.
- Input queues and output readiness apply backpressure. Apple pauses rearming
  receives and retains the pending framework buffers while Rust catches up.

The Linux transport passes existing encrypted GSO buffers directly to `sendmsg`
operations. UDP GRO metadata splits received super-datagrams before decryption.
Linux TUN segmentation and coalescing reuse the existing helpers, including their
copies when splitting super-packets. Apple TUN receive and Windows Wintun rings
need copies into mutable IP storage. Network.framework may copy or retain data
internally; this interface does not promise kernel or framework zero copy.

The native packet queues use `Rc<RefCell<_>>`, with no packet worker channels.
Existing buffer pools still use atomic bookkeeping. UniFFI control commands use
the existing command channel and typed events use a control-path mutex. Compio's
Windows/Tokio compatibility bridge uses a wait worker; packet state and encryption
remain on one thread. Optional thread affinity applies to that thread.

## Validation and scope

The Linux transport test exercises real `io_uring` loopback sends, GSO/GRO, ECN,
buffer reuse, and ordered fallback. Transport tests cover backpressure, duplicate
completions, reset generations, and leases surviving acknowledgement.

This is an opt-in prototype, not the default transport. The Apple adapter does
not yet forward resources and notifications into the existing app IPC interface,
and the standalone native client omits telemetry and flow-log upload setup.
Performance and battery improvements require measurements on each target.
