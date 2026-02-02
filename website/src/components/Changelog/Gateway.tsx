import Entry from "./Entry";
import Entries from "./Entries";
import Link from "next/link";
import ChangeItem from "./ChangeItem";
import Unreleased from "./Unreleased";

export default function Gateway() {
  const downloadLinks = [
    {
      href: "/dl/firezone-gateway/:version/x86_64",
      title: "Download for x86_64",
    },
    {
      href: "/dl/firezone-gateway/:version/aarch64",
      title: "Download for aarch64",
    },
    {
      href: "/dl/firezone-gateway/:version/armv7",
      title: "Download for armv7",
    },
  ];

  return (
    <Entries downloadLinks={downloadLinks} title="Gateway">
      <Unreleased></Unreleased>
      <Entry version="1.5.0" date={new Date("2026-02-02")}>
        <ChangeItem pull="11771">
          BREAKING: Remove support for Firezone 1.3.x Clients and lower.
        </ChangeItem>
        <ChangeItem pull="11770">
          Enables detailed flow logs for tunneled TCP and UDP connections. Set
          `FIREZONE_FLOW_LOGS=true` or `--flow-logs` to enable.
        </ChangeItem>
        <ChangeItem pull="11664">
          Adds a <code>FIREZONE_MAX_PARTITION_TIME</code> environment variable
          to configure how long the Gateway will retry connecting to the portal
          before exiting. Accepts human-readable durations like <code>5m</code>,{" "}
          <code>1h</code>, or <code>30d</code>. Defaults to 24 hours.
        </ChangeItem>
        <ChangeItem pull="11625">
          Fails faster when the initial connection to the control plane cannot
          be established, allowing faster restarts by the process manager.
        </ChangeItem>
        <ChangeItem pull="11584">
          Improves connection reliability on systems where certain UDP socket
          features are unavailable.
        </ChangeItem>
        <ChangeItem pull="11627">
          Fixes an issue where reconnections would fail if the portal host is an
          IP address.
        </ChangeItem>
        <ChangeItem pull="11626">
          Fixes an issue where reconnecting to the portal would fail if the DNS
          resolver list was empty due to a network reset or other edge case.
        </ChangeItem>
        <ChangeItem pull="11595">
          Passes the authentication token in the x-authorization header instead
          of in the URL, improving rate limiting for users behind shared IPs.
        </ChangeItem>
        <ChangeItem pull="11594">
          Implements retry with exponential backoff on 429 (Too Many Requests)
          responses from the portal.
        </ChangeItem>
        <ChangeItem pull="11804">
          Fixes an issue where connections would flap between relayed and
          direct, causing WireGuard connection timeouts.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.19" date={new Date("2025-12-23")}>
        <ChangeItem pull="10972">
          Fixes an issue where IPv6-only DNS resources could not be reached.
        </ChangeItem>
        <ChangeItem pull="11115">
          Fixes an issue where Firezone would not connect if an IPv6 interface
          is present but not routable.
        </ChangeItem>
        <ChangeItem pull="11208">
          Fixes an issue where the Gateway could reboot when the WebSocket
          connection to the portal got cut.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.18" date={new Date("2025-11-10")}>
        <ChangeItem pull="10620">
          Adds a `--log-format` CLI option to output logs as JSON.
        </ChangeItem>
        <ChangeItem pull="10796">
          Fixes an issue where packets for DNS resources would be routed to
          stale IPs after DNS record changes.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.17" date={new Date("2025-10-16")}>
        <ChangeItem pull="10367">
          Fixes a rare CPU-spike issue in case a Client connected with many
          possible IPv6 addresses.
        </ChangeItem>
        <ChangeItem pull="10349">
          Attempts to increase the system-wide parameters{" "}
          <code>core.rmem_max</code> to 128 MB and <code>core.wmem_max</code> to
          16 MB for improved performance. See the{" "}
          <Link
            className="text-accent-500 underline hover:no-underline"
            href="https://www.firezone.dev/kb/deploy/gateways#performance-tuning"
          >
            Performance tuning
          </Link>
          section for details.
        </ChangeItem>
        <ChangeItem pull="10373">
          Switches to user-space DNS resolution, allowing for accurate caching
          based on the TTL in the DNS response.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.16" date={new Date("2025-09-10")}>
        <ChangeItem pull="10231">
          Remove the FIREZONE_NUM_TUN_THREADS env variable. The Gateway will now
          always default to a single TUN thread. Using multiple threads can
          cause packet reordering which hurts TCP throughput performance.
        </ChangeItem>
        <ChangeItem pull="10076">
          Introduces graceful shutdown, allowing Clients to immediately switch
          over a new Gateway instead of waiting for the ICE timeout (~15s).
        </ChangeItem>
        <ChangeItem pull="10310">
          Fixes an issue where packets for DNS resources could get routed to the
          wrong address.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.15" date={new Date("2025-08-05")}>
        <ChangeItem pull="10109">
          Fixes an issue where connections would fail to establish in
          environments with a limited number of ports on the NAT.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.14" date={new Date("2025-07-28")}>
        <ChangeItem pull="9986">
          Fixes an issue where a Client could not establish a connection unless
          their first attempt succeeded.
        </ChangeItem>
        <ChangeItem pull="9979">
          Fixes an issue where connections in low-latency networks (between
          Client and Gateway) would fail to establish reliably.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.13" date={new Date("2025-07-22")}>
        <ChangeItem pull="9834">
          Excludes ICMP errors from the ICMP traffic filter. Those are now
          always routed back to the client.
        </ChangeItem>
        <ChangeItem pull="9816">
          Responds with ICMP errors for filtered packets.
        </ChangeItem>
        <ChangeItem pull="9812">
          Adds support for translating Time-Exceeded ICMP errors in the DNS
          resource NAT, allowing <code>tracepath</code> to work through a
          Firezone tunnel.
        </ChangeItem>
        <ChangeItem pull="9891">
          Fixes an issue where connections would sometimes take up to 90s to
          establish.
        </ChangeItem>
        <ChangeItem pull="9896">
          Fixes a potential security issue where prior resource authorizations
          would not get revoked if the Gateway was disconnected from the portal
          while access was removed.
        </ChangeItem>
        <ChangeItem pull="9894">
          Shuts down the Gateway after 15m of being disconnected from the
          portal.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.12" date={new Date("2025-06-30")}>
        <ChangeItem pull="9657">
          Fixes an issue where connections would fail to establish if the
          Gateway was under high load.
        </ChangeItem>
        <ChangeItem pull="9725">
          Fixes an issue where Firezone failed to sign-in on systems with
          non-ASCII characters in their kernel build name.
        </ChangeItem>
        <ChangeItem pull="9655">
          Allows long-lived TCP connections to remain open by increasing the NAT
          TTL to 2h.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.11" date={new Date("2025-06-19")}>
        <ChangeItem pull="9564">
          Fixes an issue where connections would fail to establish if both
          Client and Gateway were behind symmetric NAT.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.10" date={new Date("2025-06-05")}>
        <ChangeItem pull="9147">
          Fixes an issue where connections failed to establish on machines with
          multiple valid egress IPs.
        </ChangeItem>
        <ChangeItem pull="9366">
          Fixes an issue where Firezone could not start if the operating system
          refused our request to increase the UDP socket buffer sizes.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.9" date={new Date("2025-05-14")}>
        <ChangeItem pull="9059">
          Fixes an issue where ICMP unreachable errors for large packets would
          not be sent.
        </ChangeItem>
        <ChangeItem pull="9060">
          Fixes an issue where service discovery for DNS resources would fail in
          case the Gateway&apos;s started up with no network connectivity.
        </ChangeItem>
        <ChangeItem pull="9088">
          Fixes an issue where large batches of packets to the same Client got
          dropped under high load.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.8" date={new Date("2025-05-02")}>
        <ChangeItem pull="9009">
          Fixes an issue where ECN bits got erroneously cleared without updating
          the packet checksum. This caused packet loss on recent MacOS versions
          which attempt to use ECN.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.7" date={new Date("2025-04-30")}>
        <ChangeItem pull="8798">
          Improves performance of relayed connections on IPv4-only systems.
        </ChangeItem>
        <ChangeItem pull="8731">
          Improves throughput performance by requesting socket receive buffers
          of 10MB. The actual size of the buffers is capped by the operating
          system. You may need to adjust <code>net.core.rmem_max</code> for this
          to take full effect.
        </ChangeItem>
        <ChangeItem pull="8920">
          Improves connection reliability by maintaining the order of IP packets
          across GSO batches.
        </ChangeItem>
        <ChangeItem pull="8937">
          Fixes an issue where connections to DNS resources which utilise
          round-robin DNS may be interrupted whenever the Client re-queried the
          DNS name.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.6" date={new Date("2025-04-15")}>
        <ChangeItem pull="8383">
          Deprecates the NAT64 functionality in favor of sending ICMP errors to
          hint to the calling application about which IP version to use.
        </ChangeItem>
        <ChangeItem pull="8754">
          Fixes a performance regression that could lead to packet drops under
          high load.
        </ChangeItem>
        <ChangeItem pull="8765">
          Improves performance on single-core systems by defaulting to only 1
          TUN thread if we have less than 4 cores.
        </ChangeItem>
        <ChangeItem pull="7590">
          Improves performance by moving UDP sockets to a dedicated thread.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.5" date={new Date("2025-03-10")}>
        <ChangeItem pull="8124">
          Fixes a bug in the routing of DNS resources that would lead to
          &quot;Source not allowed&quot; errors in the Client logs.
        </ChangeItem>
        <ChangeItem pull="8225">
          Caches successful DNS queries for DNS resource domains for 30 seconds.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.4" date={new Date("2025-02-11")}>
        <ChangeItem pull="7944">
          Fixes an edge case where a busy Gateway could experience a deadlock
          due to a busy or unresponsive TUN device.
        </ChangeItem>
        <ChangeItem pull="8070">
          Only write logs using ANSI-escape codes if the underlying output
          stream supports it.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.3" date={new Date("2025-01-28")}>
        <ChangeItem pull="7567">
          Fixes an issue where ICMPv6&apos;s &apos;PacketTooBig&apos; errors
          were not correctly translated by the NAT64 module.
        </ChangeItem>
        <ChangeItem pull="7565">
          Fails early in case the binary is not started as <code>root</code> or
          with the
          <code>CAP_NET_ADMIN</code> capability. The check can be skipped with
          <code>--no-check</code>.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.2" date={new Date("2024-12-13")}>
        <ChangeItem pull="7210">
          Adds support for GSO (Generic Segmentation Offload), delivering
          throughput improvements of up to 60%.
        </ChangeItem>
        <ChangeItem pull="7398">
          Fixes cases where client applications such as ssh would fail to
          automatically determine the correct IP protocol version to use (4/6).
        </ChangeItem>
        <ChangeItem pull="7449">
          Uses multiple threads to read & write to the TUN device, greatly
          improving performance. The number of threads can be controlled with
          <code>FIREZONE_NUM_TUN_THREADS</code> and defaults to 2.
        </ChangeItem>
        <ChangeItem pull="7479">
          Fixes an issue where SSH connections involving NAT64 failed to
          establish.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.1" date={new Date("2024-11-15")}>
        <ChangeItem pull="7263">
          Mitigates a crash in case the maximum packet size is not respected.
        </ChangeItem>
        <ChangeItem pull="7334">
          Fixes an issue where symmetric NATs would generate unnecessary
          candidate for hole-punching.
        </ChangeItem>
        <ChangeItem pull="7120">
          Silences several unnecessary warnings from the WireGuard library.
        </ChangeItem>
        <ChangeItem pull="7341">
          Disconnects from non-compliant TURN servers.
        </ChangeItem>
        <ChangeItem pull="7342">
          Fixes a packet drop issue under high-load.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.0" date={new Date("2024-11-04")}>
        <ChangeItem pull="6960">
          Separates traffic restrictions between DNS Resources CIDR Resources,
          preventing them from interfering with each other.
        </ChangeItem>
        <ChangeItem pull="6941">
          Implements support for the new control protocol, delivering faster and
          more robust connection establishment.
        </ChangeItem>
        <ChangeItem pull="7103">
          Adds on-by-default error reporting using sentry.io. Disable by setting
          <code>FIREZONE_NO_TELEMETRY=true</code>.
        </ChangeItem>
        <ChangeItem pull="7164">
          Fixes an issue where the Gateway would fail to accept connections and
          had to be restarted.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.2" date={new Date("2024-10-02")}>
        <ChangeItem pull="6733">
          Reduces log level of the &quot;Couldn&apos;t find connection by
          IP&quot; message so that it doesn&apos;t log each time a client
          disconnects.
        </ChangeItem>
        <ChangeItem pull="6845">
          Fixes connectivity issues on idle connections by entering an
          always-on, low-power mode instead of closing them.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.1" date={new Date("2024-09-05")}>
        <ChangeItem pull="6563">
          Removes unnecessary packet buffers for a minor performance increase.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.0" date={new Date("2024-08-30")}>
        <ChangeItem pull="6434">
          Adds support for routing the Internet Resource for Clients.
        </ChangeItem>
      </Entry>
      <Entry version="1.2.0" date={new Date("2024-08-21")}>
        <ChangeItem pull="5901">
          Implements glob-like matching of domains for DNS resources.
        </ChangeItem>
      </Entry>
      <Entry version="1.1.5" date={new Date("2024-08-13")}>
        <ChangeItem pull="6276">
          Fixes a bug where relayed connections failed to establish after an
          idle period.
        </ChangeItem>
        <ChangeItem pull="6277">
          Fixes a bug where restrictive NATs caused connectivity problems.
        </ChangeItem>
      </Entry>
      <Entry version="1.1.4" date={new Date("2024-08-08")}>
        <li className="pl-2">
          Removes <code>FIREZONE_ENABLE_MASQUERADE</code> env variable.
          Masquerading is now always enabled unconditionally.
        </li>
      </Entry>
      <Entry version="1.1.3" date={new Date("2024-08-02")}>
        <li className="pl-2">
          Fixes{" "}
          <Link
            className="text-accent-500 underline hover:no-underline"
            href="https://github.com/firezone/firezone/pull/6117"
          >
            an issue
          </Link>{" "}
          where Gateways could become unresponsive after new versions of the
          Firezone infrastructure was deployed.
        </li>
      </Entry>
      <Entry version="1.1.2" date={new Date("2024-06-29")}>
        <li className="pl-2">Reduces log noise for the default log level.</li>
      </Entry>
      <Entry version="1.1.1" date={new Date("2024-06-27")}>
        <li className="pl-2">
          Fixes a minor connectivity issue that could occur for some DNS
          Resources.
        </li>
      </Entry>
      <Entry version="1.1.0" date={new Date("2024-06-19")}>
        <p className="mb-2 md:mb-4">
          This release introduces a new method of resolving and routing DNS
          Resources that is more reliable on some poorly-behaved networks. To
          use this new method, Client versions 1.1.0 or later are required.
          Client versions 1.0.x will continue to work with Gateway 1.1.x, but
          will not benefit from the new DNS resolution method.
        </p>
        <p>
          Read more about this change in the announcement post{" "}
          <Link
            href="/blog/improving-reliability-for-dns-resources"
            className="text-accent-500 underline hover:no-underline"
          >
            here
          </Link>
          .
        </p>
      </Entry>
      <Entry version="1.0.8" date={new Date("2024-06-17")}>
        This is a maintenance release with no major user-facing changes.
      </Entry>
      <Entry version="1.0.7" date={new Date("2024-06-12")}>
        This release fixes a bug where the incorrect Gateway version could be
        reported to the admin portal.
      </Entry>
      <Entry version="1.0.6" date={new Date("2024-06-11")}>
        This release contains connectivity fixes and performance improvements
        and is recommended for all users.
      </Entry>
      <Entry version="1.0.5" date={new Date("2024-05-22")}>
        Minor maintenance fixes.
      </Entry>
      <Entry version="1.0.4" date={new Date("2024-05-14")}>
        Fixes an issue detecting the correct architecture during installation
        and upgrades.
      </Entry>
      <Entry version="1.0.3" date={new Date("2024-05-08")}>
        Adds support for{" "}
        <Link
          href="/kb/deploy/resources#traffic-restrictions"
          className="hover:no-underline underline text-accent-500"
        >
          traffic restrictions
        </Link>
        .
      </Entry>
      <Entry version="1.0.2" date={new Date("2024-04-30")}>
        Fixes a big that caused invalid connections from being cleaned up
        properly.
      </Entry>
      <Entry version="1.0.1" date={new Date("224-04-29")}>
        Fixes a bug that could prevent the auto-upgrade script from working
        properly.
      </Entry>
      <Entry version="1.0.0" date={new Date("2024-04-24")}>
        Initial release.
      </Entry>
    </Entries>
  );
}
