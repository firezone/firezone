import ChangeItem from "./ChangeItem";
import Entry from "./Entry";
import Entries, { DownloadLink } from "./Entries";
import Link from "next/link";
import Unreleased from "./Unreleased";
import { OS } from ".";

export default function Headless({ os }: { os: OS }) {
  return (
    <Entries downloadLinks={downloadLinks(os)} title={title(os)}>
      {/* When you cut a release, remove any solved issues from the "known issues" lists over in `client-apps`. This must not be done when the issue's PR merges. */}
      <Unreleased>
        <ChangeItem pull="11625">
          Fails faster when the initial connection to the control plane cannot
          be established, allowing the user to retry sooner.
        </ChangeItem>
        <ChangeItem pull="11584">
          Improves connection reliability on systems where certain UDP socket
          features are unavailable.
        </ChangeItem>
        <ChangeItem pull="11654">
          Implements retry with exponential backoff for anything but 401
          responses. For example, this allows Firezone to automatically sign-in
          even if Internet Access is gated by a captive portal.
        </ChangeItem>
        <ChangeItem pull="11891">
          Fixes an issue where cached IPv6 addresses for a resource got returned
          for IPv4-only DNS resources if the setting was only changed after a
          DNS query had already been processed.
        </ChangeItem>
      </Unreleased>
      <Entry version="1.5.6" date={new Date("2026-01-06")}>
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
      <Entry version="1.5.5" date={new Date("2025-12-23")}>
        {os == OS.Linux && (
          <ChangeItem pull="10742">
            Fixes an issue where CIDR/IP resources whose routes conflict with
            the local network were not routable.
          </ChangeItem>
        )}
        <ChangeItem pull="10773">
          Fixes an issue where the order of upstream / system DNS resolvers was
          not respected.
        </ChangeItem>
        <ChangeItem pull="10914">
          Fixes an issue where concurrent DNS queries with the same ID would be
          dropped.
        </ChangeItem>
        <ChangeItem pull="11115">
          Fixes an issue where Firezone would not connect if an IPv6 interface
          is present but not routable.
        </ChangeItem>
      </Entry>
      <Entry version="1.5.4" date={new Date("2025-10-16")}>
        <ChangeItem pull="10533">
          Improves reliability by caching DNS responses as per their TTL.
        </ChangeItem>
        <ChangeItem pull="10553">
          Adds a CLI switch <code>--activate-internet-resource</code>. By
          default, the Internet Resource is now off.
        </ChangeItem>
        {os == OS.Linux && (
          <ChangeItem pull="10554">
            Fixes an issue where local LAN traffic was dropped when the Internet
            Resource was active.
          </ChangeItem>
        )}
      </Entry>
      <Entry version="1.5.3" date={new Date("2025-09-10")}>
        <ChangeItem pull="10126">
          Sets <code>FIREZONE_DNS_CONTROL=etc-resolv-conf</code> by default in
          the headless client Docker image.
        </ChangeItem>
        <ChangeItem pull="10104">
          {
            "Fixes an issue where DNS resources would resolve to a different IP after signing out and back into Firezone. This would break connectivity for long-running services that don't re-resolve DNS, like SSH sessions or mongoose."
          }
        </ChangeItem>
      </Entry>
      <Entry version="1.5.2" date={new Date("2025-07-28")}>
        <ChangeItem pull="9985">
          Fixes an issue where control plane messages could be stuck forever on
          flaky connections, requiring signing out and back in to recover.
        </ChangeItem>
        <ChangeItem pull="9891">
          Fixes an issue where connections would sometimes take up to 90s to
          establish.
        </ChangeItem>
        <ChangeItem pull="9979">
          Fixes an issue where connections in low-latency networks (between
          Client and Gateway) would fail to establish reliably.
        </ChangeItem>
        <ChangeItem pull="9999">
          Decreases connection setup time on flaky Internet connections in
          certain edge cases.
        </ChangeItem>
      </Entry>
      <Entry version="1.5.1" date={new Date("2025-07-04")}>
        <ChangeItem pull="9564">
          Fixes an issue where connections would fail to establish if both
          Client and Gateway were behind symmetric NAT.
        </ChangeItem>
        <ChangeItem pull="9725">
          Fixes an issue where Firezone failed to sign-in on systems with
          non-ASCII characters in their kernel build name.
        </ChangeItem>
        {os === OS.Windows && (
          <ChangeItem pull="9696">
            Establishes connections quicker by narrowing the set of network
            changes we react to.
          </ChangeItem>
        )}
      </Entry>
      <Entry version="1.5.0" date={new Date("2025-06-05")}>
        <ChangeItem pull="9300">
          Uses the new IP stack setting for DNS resources, which allows DNS
          resources to optionally return only A or AAAA records if configured by
          the administrator.
        </ChangeItem>
        <ChangeItem pull="9147">
          Fixes an issue where connections failed to establish on machines with
          multiple valid egress IPs.
        </ChangeItem>
        <ChangeItem pull="9366">
          Fixes an issue where Firezone could not start if the operating system
          refused our request to increase the UDP socket buffer sizes.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.8" date={new Date("2025-05-14")}>
        <ChangeItem pull="9014">
          Fixes an issue where idle connections would be slow (~60s) in
          detecting changes to network connectivity.
        </ChangeItem>
        <ChangeItem pull="9018">
          Further improves performance of relayed connections on IPv4-only
          systems.
        </ChangeItem>
        {os === OS.Windows && (
          <ChangeItem pull="9021">
            Optimizes network change detection.
          </ChangeItem>
        )}
        {os === OS.Windows && (
          <ChangeItem pull="9213">
            Adds the Client to the winget repository. You can install it via
            <code>winget install Firezone.Client.Headless</code>.
          </ChangeItem>
        )}
      </Entry>
      <Entry version="1.4.7" date={new Date("2025-04-30")}>
        <ChangeItem pull="8798">
          Improves performance of relayed connections on IPv4-only systems.
        </ChangeItem>
        {os === OS.Linux && (
          <ChangeItem pull="8731">
            Improves throughput performance by requesting socket receive buffers
            of 10MB. The actual size of the buffers is capped by the operating
            system. You may need to adjust <code>net.core.rmem_max</code> for
            this to take full effect.
          </ChangeItem>
        )}
        {os === OS.Windows && (
          <ChangeItem pull="8731">
            Improves throughput performance by requesting socket receive buffers
            of 10MB.
          </ChangeItem>
        )}
        {os === OS.Linux && (
          <ChangeItem pull="8914">
            Reduces the number of TUN threads to 1 to match other platforms and
            mitigate packet reordering issues.
          </ChangeItem>
        )}
        {os === OS.Linux && (
          <ChangeItem pull="8920">
            Improves connection reliability by maintaining the order of IP
            packets across GSO batches.
          </ChangeItem>
        )}
        {os === OS.Windows && (
          <ChangeItem pull="8920">
            Improves connection reliability by maintaining the order of IP
            packets.
          </ChangeItem>
        )}
        <ChangeItem pull="8935">
          Improves reliability for upload-intensive connections with many
          concurrent DNS queries.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.6" date={new Date("2025-04-15")}>
        {os == OS.Linux && (
          <ChangeItem pull="8754">
            Fixes a performance regression that could lead to packet drops under
            high load.
          </ChangeItem>
        )}
        <ChangeItem pull="7590">
          Improves performance by moving UDP sockets to a dedicated thread.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.5" date={new Date("2025-03-14")}>
        {os === OS.Windows && (
          <ChangeItem pull="8422">
            Applies the search domain configured in the admin portal, if any.
          </ChangeItem>
        )}
        {os === OS.Linux && (
          <ChangeItem pull="8378">
            Applies the search domain configured in the admin portal, if any.
          </ChangeItem>
        )}
      </Entry>
      <Entry version="1.4.4" date={new Date("2025-03-10")}>
        {os === OS.Linux && (
          <ChangeItem pull="8117">
            Fixes an upload speed performance regression.
          </ChangeItem>
        )}
      </Entry>
      <Entry version="1.4.3" date={new Date("2025-02-11")}>
        <ChangeItem pull="8055">
          Hides the <code>--check</code> and <code>--exit</code> CLI options
          from the help output. These are only used internally.
        </ChangeItem>
        {os === OS.Windows && (
          <ChangeItem pull="8083">
            Fixes a regression introduced in 1.4.2 where Firezone would not work
            on systems with a disabled IPv6 stack.
          </ChangeItem>
        )}
      </Entry>
      <Entry version="1.4.2" date={new Date("2025-02-10")}>
        <ChangeItem pull="8041">
          Publishes the headless client for Windows.
        </ChangeItem>
        <ChangeItem pull="8070">
          Only write logs using ANSI-escape codes if the underlying output
          stream supports it.
        </ChangeItem>
      </Entry>

      {/* The Windows headless client didn't exist before 1.4.2 */}
      {os === OS.Linux && (
        <>
          <Entry version="1.4.1" date={new Date("2025-01-28")}>
            <ChangeItem pull="7551">
              Fixes an issue where large DNS responses were incorrectly
              discarded.
            </ChangeItem>
            <ChangeItem pull="7770">
              BREAKING: Removes the positional token argument on the CLI. Use
              <code>FIREZONE_TOKEN</code> or <code>FIREZONE_TOKEN_PATH</code>{" "}
              env variables instead.
            </ChangeItem>
          </Entry>
          <Entry version="1.4.0" date={new Date("2024-12-13")}>
            <ChangeItem pull="7350">
              Allows disabling telemetry by setting
              <code>FIREZONE_NO_TELEMETRY=true</code>.
            </ChangeItem>
            <ChangeItem pull="7210">
              Adds support for GSO (Generic Segmentation Offload), delivering
              throughput improvements of up to 60%.
            </ChangeItem>
            <ChangeItem>
              Makes use of the new control protocol, delivering faster and more
              robust connection establishment.
            </ChangeItem>
            <ChangeItem pull="7449">
              Uses multiple threads to read & write to the TUN device, greatly
              improving performance.
            </ChangeItem>
            <ChangeItem pull="7477">
              Improves connection setup latency by buffering initial packets.
            </ChangeItem>
          </Entry>
          <Entry version="1.3.7" date={new Date("2024-11-15")}>
            <ChangeItem pull="7334">
              Fixes an issue where symmetric NATs would generate unnecessary
              candidate for hole-punching.
            </ChangeItem>
          </Entry>
          <Entry version="1.3.6" date={new Date("2024-11-08")}>
            <ChangeItem pull="7263">
              Mitigates a crash in case the maximum packet size is not
              respected.
            </ChangeItem>
            <ChangeItem pull="7265">
              Prevents re-connections to the portal from hanging for longer than
              5s.
            </ChangeItem>
            <ChangeItem pull="7288">
              Fixes an issue where network roaming would cause Firezone to
              become unresponsive.
            </ChangeItem>
            <ChangeItem pull="7287">
              Fixes an issue where subsequent SIGHUP signals after the first one
              were ignored.
            </ChangeItem>
          </Entry>
          <Entry version="1.3.5" date={new Date("2024-10-31")}>
            <ChangeItem>Handles DNS queries over TCP correctly.</ChangeItem>
            <ChangeItem pull="7164">
              Fixes an issue where Firezone would fail to establish connections
              to Gateways and the client had to be restarted.
            </ChangeItem>
          </Entry>
          <Entry version="1.3.4" date={new Date("2024-10-02")}>
            <ChangeItem pull="6831">
              {
                "Ensures Firefox doesn't attempt to use DNS over HTTPS when Firezone is active."
              }
            </ChangeItem>
            <ChangeItem pull="6845">
              Fixes connectivity issues on idle connections by entering an
              always-on, low-power mode instead of closing them.
            </ChangeItem>
            <ChangeItem pull="6782">
              Adds always-on error reporting using sentry.io.
            </ChangeItem>
            <ChangeItem pull="6857">
              {"Sends the motherboard's hardware ID for device verification."}
            </ChangeItem>
          </Entry>
          <Entry version="1.3.3" date={new Date("2024-09-25")}>
            <ChangeItem pull="6809">
              Fixes a bug where non-wildcard DNS resources were not prioritised
              over wildcard ones (e.g. <code>app.example.com</code> vs{" "}
              <code>*.example.com</code>).
            </ChangeItem>
          </Entry>
          <Entry version="1.3.2" date={new Date("2024-09-25")}>
            <ChangeItem pull="6765">
              Fixes a bug where DNS PTR queries by the system did not get
              answered.
            </ChangeItem>
            <ChangeItem pull="6722">
              Fixes a routing bug when one of several overlapping CIDR resources
              gets disabled / removed.
            </ChangeItem>
            <ChangeItem pull="6780">
              {
                "Fixes a bug where the Linux Clients didn't work on ZFS filesystems."
              }
            </ChangeItem>
            <ChangeItem pull="6788">
              Fixes an issue where some browsers may fail to route DNS Resources
              correctly.
            </ChangeItem>
          </Entry>
          <Entry version="1.3.1" date={new Date("2024-09-05")}>
            <ChangeItem pull="6563">
              Removes unnecessary packet buffers for a minor performance
              increase.
            </ChangeItem>
          </Entry>
          <Entry version="1.3.0" date={new Date("2024-08-30")}>
            <ChangeItem pull="6434">
              Adds the Internet Resource feature.
            </ChangeItem>
          </Entry>
          <Entry version="1.2.0" date={new Date("2024-08-21")}>
            <ChangeItem pull="5901">
              Implements glob-like matching of domains for DNS resources.
            </ChangeItem>
            <ChangeItem pull="6361">
              {
                "Connections to Gateways are now sticky for the duration of the Client's session to fix issues with long-lived TCP connections."
              }
            </ChangeItem>
          </Entry>
          <Entry version="1.1.7" date={new Date("2024-08-13")}>
            <ChangeItem pull="6276">
              Fixes a bug where relayed connections failed to establish after an
              idle period.
            </ChangeItem>
            <ChangeItem pull="6277">
              Fixes a bug where restrictive NATs caused connectivity problems.
            </ChangeItem>
          </Entry>
          <Entry version="1.1.6" date={new Date("2024-08-09")}>
            <ChangeItem pull="6233">
              Fixes an issue where the IPC service can panic during DNS
              resolution.
            </ChangeItem>
          </Entry>
          <Entry version="1.1.5" date={new Date("2024-08-08")}>
            <ChangeItem pull="6163">
              Uses <code>systemd-resolved</code> DNS control by default on Linux
            </ChangeItem>
            <ChangeItem pull="6184">
              Mitigates a bug where the Client can panic if an internal channel
              fills up
            </ChangeItem>
            <ChangeItem pull="6181">
              Improves reliability of DNS resolution of non-resources.
            </ChangeItem>
          </Entry>
          <Entry version="1.1.4" date={new Date("2024-08-02")}>
            <ChangeItem pull="6143">
              Fixes an issue where DNS queries could time out on some networks.
            </ChangeItem>
          </Entry>
          <Entry version="1.1.3" date={new Date("2024-07-05")}>
            <li className="pl-2">
              Fixes an{" "}
              <Link
                href="https://github.com/firezone/firezone/pull/5700"
                className="text-accent-500 underline hover:no-underline"
              >
                issue
              </Link>{" "}
              where a stale DNS cache could prevent traffic from routing to DNS
              Resources if they were updated while the Client was signed in.
            </li>
          </Entry>
          <Entry version="1.1.2" date={new Date("2024-07-03")}>
            <li className="pl-2">
              {
                "Prevents Firezone's stub resolver from intercepting DNS record types besides A, AAAA, and PTR. These are now forwarded to your upstream DNS resolver."
              }
            </li>
          </Entry>
          <Entry version="1.1.1" date={new Date("2024-06-29")}>
            <li className="pl-2">
              Fixes an issue that could cause Resources to be unreachable a few
              hours after roaming networks.
            </li>
            <li className="pl-2">
              Reduces noise in logs for the default log level.
            </li>
          </Entry>
          <Entry version="1.1.0" date={new Date("2024-06-27")}>
            <li className="pl-2">
              Introduces the new DNS routing system supported by 1.1.0 Gateways
              which results in much more stable connections for DNS Resources,
              especially when wildcards are used.
            </li>
            <li className="pl-2">
              Improves reliability when roaming between networks.
            </li>
            <li className="pl-2">
              Closes idle connections to Gateways that have not seen traffic for
              more than 5 minutes which reduces power consumption when not
              accessing Resources.
            </li>
            <li className="pl-2">
              Updates log file endings to JSONL and adds syslog-style logs for
              easier readability.
            </li>
            <p>
              <strong>Note:</strong> Client versions 1.1.x are incompatible with
              Gateways running 1.0.x.
            </p>
          </Entry>
          <Entry version="1.0.8" date={new Date("2024-06-17")}>
            This is a maintenance release with no major user-facing changes.
          </Entry>
          <Entry version="1.0.7" date={new Date("2024-06-12")}>
            This release fixes a bug where the incorrect Client version was
            reported to the admin portal.
          </Entry>
          <Entry version="1.0.6" date={new Date("2024-06-11")}>
            This release contains connectivity fixes and performance
            improvements and is recommended for all users.
          </Entry>
          <Entry version="1.0.5" date={new Date("2024-05-22")}>
            This is a maintenance release with no major user-facing changes.
          </Entry>
          <Entry version="1.0.4" date={new Date("2024-05-14")}>
            This is a maintenance release with no major user-facing changes.
          </Entry>
          <Entry version="1.0.3" date={new Date("2024-05-08")}>
            Maintenance release.
          </Entry>
          <Entry version="1.0.2" date={new Date("2024-04-30")}>
            This release reverts a change that could cause connectivity issues
            seen by some users.
          </Entry>
          <Entry version="1.0.1" date={new Date("2024-04-29")}>
            Update the upgrade URLs used to check for new versions.
          </Entry>
          <Entry version="1.0.0" date={new Date("2024-04-24")}>
            Initial release.
          </Entry>
        </>
      )}
    </Entries>
  );
}

function downloadLinks(os: OS): DownloadLink[] {
  switch (os) {
    case OS.Windows:
      return [
        {
          href: "/dl/firezone-client-headless-windows/:version/x86_64",
          title: "Download for x86_64",
        },
      ];
    case OS.Linux:
      return [
        {
          href: "/dl/firezone-client-headless-linux/:version/x86_64",
          title: "Download for x86_64",
        },
        {
          href: "/dl/firezone-client-headless-linux/:version/aarch64",
          title: "Download for aarch64",
        },
        {
          href: "/dl/firezone-client-headless-linux/:version/armv7",
          title: "Download for armv7",
        },
      ];
  }
}

function title(os: OS): string {
  switch (os) {
    case OS.Windows:
      return "Windows Headless";
    case OS.Linux:
      return "Linux Headless";
  }
}
