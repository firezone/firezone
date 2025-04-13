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
      <Unreleased>
        <ChangeItem pull="8383">
          Deprecates the NAT64 functionality in favor of sending ICMP errors.
        </ChangeItem>
        <ChangeItem pull="8754">
          Fixes a performance regression that could lead to packet drops under
          high load.
        </ChangeItem>
        <ChangeItem pull="8765">
          Improves performance by defaulting to only 1 TUN thread on single-core
          systems.
        </ChangeItem>
      </Unreleased>
      <Entry version="1.4.5" date={new Date("2025-03-10")}>
        <ChangeItem pull="8124">
          Fixes a bug in the routing of DNS resources that would lead to "Source
          not allowed" errors in the Client logs.
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
          Fixes an issue where ICMPv6's `PacketTooBig' errors were not correctly
          translated by the NAT64 module.
        </ChangeItem>
        <ChangeItem pull="7565">
          Fails early in case the binary is not started as `root` or with the
          `CAP_NET_ADMIN` capability. The check can be skipped with
          `--no-check`.
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
          `FIREZONE_NUM_TUN_THREADS` and defaults to 2.
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
          `FIREZONE_NO_TELEMETRY=true`.
        </ChangeItem>
        <ChangeItem pull="7164">
          Fixes an issue where the Gateway would fail to accept connections and
          had to be restarted.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.2" date={new Date("2024-10-02")}>
        <ChangeItem pull="6733">
          Reduces log level of the "Couldn't find connection by IP" message so
          that it doesn't log each time a client disconnects.
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
          Removes `FIREZONE_ENABLE_MASQUERADE` env variable. Masquerading is now
          always enabled unconditionally.
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
