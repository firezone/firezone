import ChangeItem from "./ChangeItem";
import Entries from "./Entries";
import Entry from "./Entry";
import Link from "next/link";
import Unreleased from "./Unreleased";
import { Route } from "next";

export default function Android() {
  const downloadLinks = [
    {
      href: "https://play.google.com/store/apps/details?id=dev.firezone.android",
      title: "Download on Google Play",
    },
    {
      href: "/dl/firezone-client-android/:version",
      title: "Download APK",
    },
  ];

  return (
    <Entries downloadLinks={downloadLinks} title="Android">
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
        <ChangeItem pull="11654">
          Implements retry with exponential backoff for anything but 401
          responses. For example, this allows Firezone to automatically sign-in
          even if Internet Access is gated by a captive portal.
        </ChangeItem>
        <ChangeItem pull="11804">
          Fixes an issue where connections would flap between relayed and
          direct, causing WireGuard connection timeouts.
        </ChangeItem>
        <ChangeItem pull="11891">
          Fixes an issue where cached IPv6 addresses for a resource got returned
          for IPv4-only DNS resources if the setting was only changed after a
          DNS query had already been processed.
        </ChangeItem>
      </Unreleased>
      <Entry version="1.5.8" date={new Date("2025-12-23")}>
        <ChangeItem pull="11077">
          Fixes an issue where the authentication link would not open in the
          correct app.
        </ChangeItem>
        <ChangeItem pull="11115">
          Fixes an issue where Firezone would not connect if an IPv6 interface
          is present but not routable.
        </ChangeItem>
      </Entry>
      <Entry version="1.5.7" date={new Date("2025-12-05")}>
        <ChangeItem pull="10752">
          Fixes an issue where the reported client version was out of date.
        </ChangeItem>
        <ChangeItem pull="10773">
          Fixes an issue where the order of upstream / system DNS resolvers was
          not respected.
        </ChangeItem>
        <ChangeItem pull="10914">
          Fixes an issue where concurrent DNS queries with the same ID would be
          dropped.
        </ChangeItem>
      </Entry>
      <Entry version="1.5.6" date={new Date("2025-10-28")}>
        <ChangeItem pull="10667">
          Fixes an issue where the Tunnel service would crash when trying to
          connect Firezone without an Internet connection.
        </ChangeItem>
      </Entry>
      <Entry version="1.5.5" date={new Date("2025-10-18")}>
        <ChangeItem pull="10509">
          Fixes an issue where the Internet Resource could be briefly active on
          startup, despite it being disabled.
        </ChangeItem>
        <ChangeItem pull="10533">
          Improves reliability by caching DNS responses as per their TTL.
        </ChangeItem>
      </Entry>
      <Entry version="1.5.4" date={new Date("2025-09-18")}>
        <ChangeItem pull="10371">
          Fixes a bug that could prevent sign-ins from completing successfully
          if Firefox is set as the default browser.
        </ChangeItem>
        <ChangeItem pull="10104">
          {
            "Fixes an issue where DNS resources would resolve to a different IP after signing out and back into Firezone. This would break connectivity for long-running services that don't re-resolve DNS, like SSH sessions or mongoose."
          }
        </ChangeItem>
      </Entry>
      <Entry version="1.5.3" date={new Date("2025-08-05")}>
        <ChangeItem pull="9985">
          Fixes an issue where control plane messages could be stuck forever on
          flaky connections, requiring signing out and back in to recover.
        </ChangeItem>
        <ChangeItem pull="9725">
          Fixes an issue where Firezone failed to sign-in on systems with
          non-ASCII characters in their kernel build name.
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
      <Entry version="1.5.2" date={new Date("2025-06-30")}>
        <ChangeItem pull="9621">
          {
            "Fixes an issue where the VPN permission screen wouldn't dismiss after granting the VPN permission."
          }
        </ChangeItem>
        <ChangeItem pull="9564">
          Fixes an issue where connections would fail to establish if both
          Client and Gateway were behind symmetric NAT.
        </ChangeItem>
      </Entry>
      <Entry version="1.5.1" date={new Date("2025-06-04")}>
        <ChangeItem pull="9394">
          Fixes a minor issue that would cause background service panic when
          signing out.
        </ChangeItem>
      </Entry>
      <Entry version="1.5.0" date={new Date("2025-06-02")}>
        <ChangeItem pull="9300">
          Uses the new IP stack setting for DNS resources, which allows DNS
          resources to optionally return only A or AAAA records if configured by
          the administrator.
        </ChangeItem>
        <ChangeItem pull="9227">
          {
            "Adds full support for managed configurations to configure the client using your organization's MDM solution. See the "
          }
          <Link
            href={"/kb/deploy/clients#provision-with-mdm" as Route}
            className="text-accent-500 underline hover:no-underline"
          >
            knowledge base article
          </Link>{" "}
          for more details.
        </ChangeItem>
        <ChangeItem pull="9014">
          Fixes an issue where idle connections would be slow (~60s) in
          detecting changes to network connectivity.
        </ChangeItem>
        <ChangeItem pull="9018">
          Further improves performance of relayed connections on IPv4-only
          systems.
        </ChangeItem>
        <ChangeItem pull="9093">
          Fixes a rare panic when the DNS servers on the system would change
          while Firezone is connected.
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
      <Entry version="1.4.8" date={new Date("2025-04-30")}>
        <ChangeItem pull="8920">
          Improves connection reliability by maintaining the order of IP packets
          across GSO batches.
        </ChangeItem>
        <ChangeItem pull="8926">
          Rolls over to a new log-file as soon as logs are cleared.
        </ChangeItem>
        <ChangeItem pull="8935">
          Improves reliability for upload-intensive connections with many
          concurrent DNS queries.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.7" date={new Date("2025-04-21")}>
        <ChangeItem pull="8798">
          Improves performance of relayed connections on IPv4-only systems.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.6" date={new Date("2025-04-15")}>
        <ChangeItem pull="8754">
          Fixes a performance regression that could lead to packet drops under
          high load.
        </ChangeItem>
        <ChangeItem pull="7590">
          Improves performance by moving UDP sockets to a dedicated thread.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.5" date={new Date("2025-03-15")}>
        <ChangeItem pull="8445">
          {
            "Fixes a bug where search domains changes weren't applied if already signed in."
          }
        </ChangeItem>
      </Entry>
      <Entry version="1.4.4" date={new Date("2025-03-14")}>
        <ChangeItem pull="8436">
          Applies the search domain configured in the admin portal, if any.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.3" date={new Date("2025-03-10")}>
        <ChangeItem pull="8376">
          Fixes a bug where UI controls could overlap with system controls on
          some devices.
        </ChangeItem>
        <ChangeItem pull="8286">
          Fixes a bug that prevented certain Resource fields from being updated
          when they were updated in the admin portal.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.2" date={new Date("2025-02-16")}>
        <ChangeItem pull="8117">
          Fixes an upload speed performance regression.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.1" date={new Date("2025-01-28")}>
        <ChangeItem pull="7891">
          Substantially reduces memory usage when sending large amounts of data.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.0" date={new Date("2025-01-02")}>
        <ChangeItem pull="7599">
          The Android app is now distributed{" "}
          <Link
            href="https://www.github.com/firezone/firezone/releases"
            className="text-accent-500 underline hover:no-underline"
          >
            via GitHub Releases in addition
          </Link>
          to the Google Play Store.
        </ChangeItem>
        <ChangeItem pull="7334">
          Fixes an issue where symmetric NATs would generate unnecessary
          candidate for hole-punching.
        </ChangeItem>
        <ChangeItem pull="7210">
          Adds support for GSO (Generic Segmentation Offload), delivering
          throughput improvements of up to 60%.
        </ChangeItem>
        <ChangeItem>
          Makes use of the new control protocol, delivering faster and more
          robust connection establishment.
        </ChangeItem>
        <ChangeItem pull="7477">
          Improves connection setup latency by buffering initial packets.
        </ChangeItem>
        <ChangeItem pull="7551">
          Fixes an issue where large DNS responses were incorrectly discarded.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.7" date={new Date("2024-11-08")}>
        <ChangeItem pull="7263">
          Mitigates a crash in case the maximum packet size is not respected.
        </ChangeItem>
        <ChangeItem pull="7265">
          Prevents re-connections to the portal from hanging for longer than 5s.
        </ChangeItem>
        <ChangeItem pull="7288">
          Fixes an issue where network roaming would cause Firezone to become
          unresponsive.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.6" date={new Date("2024-10-31")}>
        <ChangeItem>Handles DNS queries over TCP correctly.</ChangeItem>
        <ChangeItem pull="7151">
          Adds always-on error reporting using sentry.io.
        </ChangeItem>
        <ChangeItem pull="7160">
          Fixes an issue where notifications would sometimes not get delivered
          when Firezone was active.
        </ChangeItem>
        <ChangeItem pull="7164">
          Fixes an issue where Firezone would fail to establish connections to
          Gateways and the user had to sign-out and in again.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.5" date={new Date("2024-10-03")}>
        <ChangeItem pull="6831">
          {
            "Ensures Firefox doesn't attempt to use DNS over HTTPS when Firezone is active."
          }
        </ChangeItem>
        <ChangeItem pull="6845">
          Fixes connectivity issues on idle connections by entering an
          always-on, low-power mode instead of closing them.
        </ChangeItem>
        <ChangeItem pull="6857">
          Sends the Firebase Installation ID for device verification.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.4" date={new Date("2024-09-26")}>
        <ChangeItem pull="6809">
          Fixes a bug where non-wildcard DNS resources were not prioritised over
          wildcard ones (e.g. <code>app.example.com</code> vs{" "}
          <code>*.example.com</code>).
        </ChangeItem>
      </Entry>
      <Entry version="1.3.3" date={new Date("2024-09-24")}>
        <ChangeItem pull="6707">
          Resetting the settings now resets the list of favorited Resources,
          too.
        </ChangeItem>
        <ChangeItem pull="6765">
          Fixes a bug where DNS PTR queries by the system did not get answered.
        </ChangeItem>
        <ChangeItem pull="6722">
          Fixes a routing bug when one of several overlapping CIDR resources
          gets disabled / removed.
        </ChangeItem>
        <ChangeItem pull="6788">
          Fixes an issue where some browsers may fail to route DNS Resources
          correctly.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.2" date={new Date("2024-09-05")}>
        <ChangeItem pull="6605">
          Fixes another bug where the tunnel would immediately disconnect after
          connecting.
        </ChangeItem>
        <ChangeItem pull="6518">
          Minor improvements to the look of the internet resource and makes the
          Internet resource off by default.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.1" date={new Date("2024-08-31")}>
        <ChangeItem pull="6517">
          Fixes a bug where the tunnel would immediately disconnect after
          connecting.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.0" date={new Date("2024-08-30")}>
        <ChangeItem pull="6424">
          Fixes a bug where packets would be lost when a connection is first
          established to a gateway, due to routes being updated with no actual
          change.
        </ChangeItem>
        <ChangeItem pull="6405">
          Shows the Git SHA corresponding to the build on the Settings -&gt;
          Advanced screen.
        </ChangeItem>
        <ChangeItem pull="6495">
          {
            "Fixes a bug where the Firezone tunnel wasn't shut down properly if you disconnect the VPN in system settings."
          }
        </ChangeItem>
        <ChangeItem pull="6434">Adds the Internet Resource feature.</ChangeItem>
      </Entry>
      <Entry version="1.2.0" date={new Date("2024-08-21")}>
        <ChangeItem pull="5901">
          Implements glob-like matching of domains for DNS resources.
        </ChangeItem>
        <ChangeItem pull="6361">
          {
            "Connections to Gateways are now sticky for the duration of the Client's session. This fixes potential issues maintaining long-lived TCP connections to Gateways in a high-availability setup."
          }
        </ChangeItem>
      </Entry>
      <Entry version="1.1.6" date={new Date("2024-08-13")}>
        <ChangeItem pull="6276">
          Fixes a bug where relayed connections failed to establish after an
          idle period.
        </ChangeItem>
        <ChangeItem pull="6277">
          Fixes a bug where restrictive NATs caused connectivity problems.
        </ChangeItem>
      </Entry>
      <Entry version="1.1.5" date={new Date("2024-08-10")}>
        <ChangeItem pull="6107">
          Adds the ability to mark Resources as favorites.
        </ChangeItem>
        <ChangeItem pull="6181">
          Improves reliability of DNS resolution of non-resources.
        </ChangeItem>
      </Entry>
      <Entry version="1.1.4" date={new Date("2024-08-02")}>
        <li className="pl-2">
          Fixes{" "}
          <Link
            href="https://github.com/firezone/firezone/pull/6143"
            className="text-accent-500 underline hover:no-underline"
          >
            an issue
          </Link>{" "}
          where DNS queries could time out on some networks.
        </li>
      </Entry>
      <Entry version="1.1.3" date={new Date("2024-07-06")}>
        <li className="pl-2">
          Fixes{" "}
          <Link
            href="https://github.com/firezone/firezone/issues/5781"
            className="text-accent-500 underline hover:no-underline"
          >
            an issue
          </Link>{" "}
          where the app would crash if IPv6 scopes were present in the DNS
          servers discovered on the local system.
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
          more than 5 minutes which reduces power consumption when not accessing
          Resources.
        </li>
        <li className="pl-2">
          Updates log file endings to JSONL and adds syslog-style logs for
          easier readability.
        </li>
        <li className="pl-2">Fixes various crashes.</li>
        <p>
          <strong>Note:</strong> Client versions 1.1.x are incompatible with
          Gateways running 1.0.x.
        </p>
      </Entry>
      <Entry version="1.0.4" date={new Date("2024-06-13")}>
        This release fixes a bug where the incorrect Client version could be
        reported to the admin portal.
      </Entry>
      <Entry version="1.0.3" date={new Date("2024-06-12")}>
        This release contains connectivity bugfixes and performance
        improvements.
      </Entry>
      <Entry version="1.0.2" date={new Date("2024-04-30")}>
        This release reverts a change that could cause connectivity issues in
        some cases.
      </Entry>
      <Entry version="1.0.1" date={new Date("2024-04-29")}>
        This release contains reliability and performance fixes and is
        recommended for all users.
      </Entry>
      <Entry version="1.0.0" date={new Date("2024-03-12")}>
        Initial release.
      </Entry>
    </Entries>
  );
}
