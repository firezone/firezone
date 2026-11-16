# app-filter

Application-aware filtering of traffic that enters the Firezone tunnel.

## Semantics

Every platform enforces the same policy:

- `allowedApplications` lists the only applications that may send traffic into the tunnel. Unset means every application may; an empty list denies every application.
- A destination is protected when the tunnel routes it. With the Internet Resource enabled, that is all internet traffic.
- The tunnel's DNS servers are never filtered, because the system resolver sends those queries on behalf of every application.
- A flow whose application the platform cannot identify is denied on protected destinations. Unknown is never treated as approved.
- Unlisted applications keep ordinary internet access to destinations the tunnel does not route.
- An allowed flow still goes through the normal Resource authorization on the Gateway. The filter never routes traffic.

`Filter::decide` in `src/policy.rs` is the reference implementation with tests. The Swift (`AppFilterPolicy`) and Kotlin (VPN app lists) ports follow it.

## Identity and enforcement per platform

| Platform | Application identifier | Enforcement | Policy channel |
| --- | --- | --- | --- |
| Windows | Absolute executable path | WFP filters at the ALE connect layers, scoped to the tunnel adapter LUID, in a dynamic session | `allowedApplications` under `HKLM\Software\Policies\Firezone` (ADMX) |
| Linux | Absolute executable path | cgroup `connect4/6` and `sendmsg4/6` eBPF programs; `sched_process_*` tracepoints track which processes run a listed executable | `FIREZONE_ALLOWED_APPLICATIONS` in the service environment, or `--allowed-applications` on the headless client |
| macOS | Code-signing identifier (bundle ID) from the flow's audit token | `NEFilterDataProvider` in the system extension beside the packet tunnel | `allowedApplications` in the `dev.firezone.firezone` profile |
| iOS | `sourceAppIdentifier` | `NEFilterDataProvider` appex (`dev.firezone.firezone.app-filter`), installed by MDM on supervised devices | `allowedApplications` in managed app configuration |
| Android | Package name | `VpnService.Builder.addAllowedApplication`, the OS keeps unlisted apps off the VPN entirely | `allowedApplications` managed configuration |

The identifiers say which program opened a socket. They do not prove the program is intact, and an approved program can still act on behalf of another one.

## Building the Linux program

The eBPF program lives in `../app-filter-ebpf` and is only built with the `ebpf` cargo feature, which needs the nightly toolchain and `bpf-linker` (`mise run install-ebpf-toolchain`). A build without the feature refuses to bring up a tunnel when a policy is configured, so a policy never runs unenforced. Set `AYA_BUILD_SKIP=1` to type-check the loader without the toolchain.

The Tunnel service's systemd unit grants `CAP_BPF` and `CAP_PERFMON` and allows the `bpf` and `perf_event_open` syscalls for this.
