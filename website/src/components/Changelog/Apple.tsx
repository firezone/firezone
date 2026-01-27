import { Route } from "next";
import Link from "next/link";
import Entry from "./Entry";
import Entries from "./Entries";
import ChangeItem from "./ChangeItem";
import Unreleased from "./Unreleased";

export default function Apple() {
  const downloadLinks = [
    {
      href: "https://apps.apple.com/us/app/firezone/id6443661826",
      title: "Download on App Store for macOS and iOS",
    },
    {
      href: "/dl/firezone-client-macos/:version",
      title: "Download standalone DMG file for macOS",
    },
    {
      href: "/dl/firezone-client-macos/pkg/:version",
      title: "Download standalone installer PKG file for macOS",
    },
  ];

  return (
    <Entries downloadLinks={downloadLinks} title="macOS / iOS">
      {/* When you cut a release, remove any solved issues from the "known issues" lists over in `client-apps`. This must not be done when the issue's PR merges. */}
      <Unreleased>
        <ChangeItem pull="11901">
          Fixes an issue where the tunnel may not come up after a fresh install
          of the Firezone client.
        </ChangeItem>
        <ChangeItem pull="11892">
          Exports logs in plain text format instead of JSONL for easier reading.
        </ChangeItem>
        <ChangeItem pull="11834">
          Fixes an issue where the tunnel might hang or crash on iOS immediately
          after signing in.
        </ChangeItem>
        <ChangeItem pull="11659">
          Prevents unbounded log growth by enforcing a 100 MB log size cap with
          automatic cleanup of oldest files.
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
      <Entry version="1.5.12" date={new Date("2026-01-20")}>
        <ChangeItem pull="11735">
          Fixes an issue on iOS where the system resolvers could not be reliably
          read, causing DNS queries to fail system-wide.
        </ChangeItem>
        <ChangeItem pull="11625">
          Fails faster when the initial connection to the control plane cannot
          be established, allowing the user to retry sooner.
        </ChangeItem>
        <ChangeItem pull="11634">
          Bumps minimum macOS version from 12.4 to 13.0 (Ventura) to enable
          SwiftUI MenuBarExtra API.
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
      </Entry>
      <Entry version="1.5.11" date={new Date("2025-12-23")}>
        <ChangeItem pull="11141">
          Fixes an issue where spurious resource updates would result in
          perceived network interruptions resulting in errors like{" "}
          <code>ERR_NETWORK_CHANGED</code> in Google Chrome.
        </ChangeItem>
        <ChangeItem pull="11115">
          Fixes an issue where Firezone would not connect if an IPv6 interface
          is present but not routable.
        </ChangeItem>
      </Entry>
      <Entry version="1.5.10" date={new Date("2025-12-04")}>
        <ChangeItem pull="10986">
          Fixes a minor race condition that could arise on sign out.
        </ChangeItem>
        <ChangeItem pull="10855">
          Fixes an issue on macOS where the <code>utun</code> index would
          auto-increment by itself on configuration updates.
        </ChangeItem>
        <ChangeItem pull="10752">
          Fixes an issue where the reported client version was out of date.
        </ChangeItem>
        <ChangeItem pull="10773">
          Fixes an issue where the order of upstream / system DNS resolvers was
          not respected.
        </ChangeItem>
        <ChangeItem pull="10824">
          Adds support for <code>hideResourceList</code> managed configuration
          key to hide the Resource List in the macOS and iOS apps.
        </ChangeItem>
        <ChangeItem pull="10914">
          Fixes an issue where concurrent DNS queries with the same ID would be
          dropped.
        </ChangeItem>
        <ChangeItem pull="10965">
          Fixes an issue where some packets would get dropped under high
          throughput scenarios.
        </ChangeItem>
      </Entry>
      <Entry version="1.5.9" date={new Date("2025-10-20")}>
        <ChangeItem pull="10603">
          Fixes an issue on macOS where DNS resources might fail to be routed
          properly after many (150+) Firezone session restarts.
        </ChangeItem>
        <ChangeItem pull="10509">
          Fixes an issue where the Internet Resource could be briefly active on
          startup, despite it being disabled.
        </ChangeItem>
        <ChangeItem pull="10533">
          Improves reliability by caching DNS responses as per their TTL.
        </ChangeItem>
        <ChangeItem pull="10567">
          Fixes an issue where the Resources menu would not populate when
          launching the app while already connected.
        </ChangeItem>
      </Entry>
      <Entry version="1.5.8" date={new Date("2025-09-10")}>
        <ChangeItem pull="10313">
          Fixes an issue where multiple concurrent Firezone macOS clients could
          run simultaneously. We now enforce a single instance of the client.
        </ChangeItem>
        <ChangeItem pull="10224">
          Fixes a minor DNS cache bug where newly-added DNS resources may not
          resolve for a few seconds after showing up in the Resource List.
        </ChangeItem>
        <ChangeItem pull="10104">
          Fixes an issue where DNS resources would resolve to a different IP
          after signing out and back into Firezone. This would break
          connectivity for long-running services that don&apos;t re-resolve DNS,
          like SSH sessions or mongoose.
        </ChangeItem>
      </Entry>
      <Entry version="1.5.7" date={new Date("2025-08-07")}>
        <ChangeItem pull="10143">
          Fixes an issue on iOS 17 and below that caused the tunnel to crash
          after signing in. This was due to a change in how newer versions of
          Xcode handle linking against referenced libraries. iOS 18 and higher
          is unaffected.
        </ChangeItem>
      </Entry>
      <Entry version="1.5.6" date={new Date("2025-08-02")}>
        <ChangeItem pull="10075">
          Fixes an issue on iOS where the tunnel may never fully come up after
          signing in due to a network connectivity reset loop.
        </ChangeItem>
        <ChangeItem pull="10056">
          Fixes an issue where connectivity could be lost for up to 20 seconds
          after waking from sleep.
        </ChangeItem>
      </Entry>
      <Entry version="1.5.5" date={new Date("2025-07-28")}>
        <ChangeItem pull="10022">
          Fixes a bug on iOS where network connectivity changes (such as from
          WiFi to cellular) may result in the wrong default system DNS resolvers
          being read, which could prevent DNS resources from working correctly.
        </ChangeItem>
        <ChangeItem pull="10019">
          Fixes an issue on recent versions of iOS where the export logs sheet
          would open and then immediately close.
        </ChangeItem>
        <ChangeItem pull="9991">
          Fixes an issue where only the first system DNS resolver was used to
          forward queries instead of all found ones.
        </ChangeItem>
        <ChangeItem pull="9985">
          Fixes an issue where control plane messages could be stuck forever on
          flaky connections, requiring signing out and back in to recover.
        </ChangeItem>
        <ChangeItem pull="9993">
          Fixes an issue where DNS resolvers could be lost upon waking from
          sleep, leading to broken Internet connectivity.
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
      <Entry version="1.5.4" date={new Date("2025-07-11")}>
        <ChangeItem pull="9597">
          Fixes an issue where certain log files would not be recreated after
          logs were cleared.
        </ChangeItem>
        <ChangeItem pull="9536">
          Uses <code>.zip</code> to compress logs instead of Apple Archive.
        </ChangeItem>
        <ChangeItem pull="9725">
          Fixes an issue where Firezone failed to sign-in on systems with
          non-ASCII characters in their kernel build name.
        </ChangeItem>
      </Entry>
      <Entry version="1.5.3" date={new Date("2025-06-19")}>
        <ChangeItem pull="9564">
          Fixes an issue where connections would fail to establish if both
          Client and Gateway were behind symmetric NAT.
        </ChangeItem>
      </Entry>
      <Entry version="1.5.2" date={new Date("2025-06-03")}>
        <ChangeItem pull="9300">
          Uses the new IP stack setting for DNS resources, which allows DNS
          resources to optionally return only A or AAAA records if configured by
          the administrator.
        </ChangeItem>
        <ChangeItem pull="9366">
          Fixes an issue where Firezone could not start if the operating system
          refused our request to increase the UDP socket buffer sizes.
        </ChangeItem>
      </Entry>
      <Entry version="1.5.1" date={new Date("2025-06-01")}>
        <ChangeItem pull="9308">
          Fixes an issue where the network extension could crash when viewing
          the diagnostic logs pane in app settings.
        </ChangeItem>
        <ChangeItem pull="9308">
          Fixes a minor issue where the network extension process could crash
          when signing out.
        </ChangeItem>
        <ChangeItem pull="9242">
          Fixes a rare bug that could prevent certain IPv6 DNS upstream
          resolvers from being used if they contained an interface scope
          specifier.
        </ChangeItem>
      </Entry>
      <Entry version="1.5.0" date={new Date("2025-05-26")}>
        <ChangeItem pull="9230">
          Finalizes the managed configuration support for the macOS client. For
          details on how to configure this, see{" "}
          <Link
            href={"/kb/deploy/clients#provision-with-mdm" as Route}
            className="text-accent-500 underline hover:no-underline"
          >
            the knowledge base article
          </Link>
          .
        </ChangeItem>
        <ChangeItem pull="9231">
          Fixes a minor bug where the app would report a minor error in the
          backend when quitting while signed out.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.15" date={new Date("2025-05-23")}>
        <ChangeItem pull="9204">
          Adds a
          <Link
            href={
              "/policy-templates/macos/profile-manifests/dev.firezone.firezone.plist" as Route
            }
            className="text-accent-500 underline hover:no-underline"
          >
            profile manifest
          </Link>
          for easily generating managed configuration files for the macOS app
          using the iMazing Profile Editor.
        </ChangeItem>
        <ChangeItem pull="9196">
          Adds managed configuration support for the macOS application. This
          allows applying using your MDM provider to configure the app on
          managed devices using <code>mobileconfig</code> files.
        </ChangeItem>
        <ChangeItem pull="9168">
          Adds a &quot;Connect on start&quot; setting, and another &quot;Start
          on login&quot; setting specific to just the macOS app.
        </ChangeItem>
        <ChangeItem pull="9167">
          Disables update checking and notifications for the App Store variant
          of the macOS client.
        </ChangeItem>
        <ChangeItem pull="9119">
          Automatically saves the account slug after the first sign in, and adds
          a new
          <code>General</code> tab in Settings to allow updating it.
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
      </Entry>
      <Entry version="1.4.14" date={new Date("2025-05-02")}>
        <ChangeItem pull="9005">
          Fixes an issue where the IP checksum was not updated when ECN bits
          were set. This caused packet loss on recent MacOS versions which
          default to using ECN.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.13" date={new Date("2025-04-30")}>
        <ChangeItem pull="8731">
          Improves throughput performance by requesting socket receive buffers
          of 10MB. The actual size of the buffers is capped by the operating
          system. You may need to adjust <code>kern.ipc.maxsockbuf</code> for
          this to take full effect.
        </ChangeItem>
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
      <Entry version="1.4.12" date={new Date("2025-04-21")}>
        <ChangeItem pull="8798">
          Improves performance of relayed connections on IPv4-only systems.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.11" date={new Date("2025-04-18")}>
        <ChangeItem pull="8814">
          Fixes an issue where the app would hang on launch if another VPN app
          was connected.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.10" date={new Date("2025-04-17")}>
        <ChangeItem pull="8795">
          Publishes an installer package for macOS in addition to the DMG file.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.9" date={new Date("2025-04-15")}>
        <ChangeItem pull="7590">
          Improves performance by moving UDP sockets to a dedicated thread.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.8" date={new Date("2025-03-21")}>
        <ChangeItem pull="8477">
          Fixes an issue where the app would not auto-connect on launch.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.7" date={new Date("2025-03-14")}>
        <ChangeItem pull="8421">
          Applies the search domain configured in the admin portal, if any.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.6" date={new Date("2025-03-11")}>
        <ChangeItem pull="8282">
          Shows friendlier and more-human alert messages when something goes
          wrong.
        </ChangeItem>
        <ChangeItem pull="8286">
          Fixes a bug that prevented certain Resource fields from being updated
          when they were updated in the admin portal.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.5" date={new Date("2025-02-24")}>
        <ChangeItem pull="8251">
          Fixes an issue where the update checker would not properly notify the
          user about new updates available on macOS.
        </ChangeItem>
        <ChangeItem pull="8248">
          Fixes a crash on macOS that could occur when an application update
          become available.
        </ChangeItem>
        <ChangeItem pull="8249">
          Fixes a regression that caused a crash if &quot;Open menu&quot; was
          clicked in the Welcome screen.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.4" date={new Date("2025-02-24")}>
        <ChangeItem pull="8202">
          Fixes a crash that occurred if the system reports invalid DNS servers.
        </ChangeItem>
        <ChangeItem pull="8237">
          Fixes a minor memory leak that would occur each time you sign in.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.3" date={new Date("2025-02-16")}>
        <ChangeItem pull="8122">
          Fixes a rare crash that could occur when dismissing the update
          available notification.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.2" date={new Date("2025-02-13")}>
        <ChangeItem pull="8104">
          Fixes a minor memory leak that could occur after being unexpectedly
          disconnected.
        </ChangeItem>
        <ChangeItem pull="8091">
          Fixes a bug that prevented exporting logs from the macOS app more than
          once.
        </ChangeItem>
        <ChangeItem pull="8090">
          Improves app launch time by asynchronously loading icons upon app
          launch.
        </ChangeItem>
        <ChangeItem pull="8066">
          Improves MenuBar list responsiveness on macOS.
        </ChangeItem>
        <ChangeItem pull="8064">
          Fixes a bug that might cause the UI process to crash when the Resource
          list is updated.
        </ChangeItem>
        <ChangeItem pull="7996">
          No longer shows an error dialog if the sign in process is canceled.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.1" date={new Date("2025-01-29")}>
        <ChangeItem>Fixes a few minor UI hangs.</ChangeItem>
        <ChangeItem pull="7890">
          Fixes a minor memory leak that occurred when roaming networks.
        </ChangeItem>
        <ChangeItem pull="8091">
          Fixes a bug that prevented exporting logs from the macOS app more than
          once.
        </ChangeItem>
        <ChangeItem pull="7891">
          Substantially reduces the amount of memory usage when sending large
          amount of data to many different Gateways.
        </ChangeItem>
        <ChangeItem>
          Improves UX around installing the system extension, VPN configuration,
          and granting notifications by showing the user actionable alerts if
          errors occur.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.0" date={new Date("2025-01-16")}>
        <ChangeItem pull="7581">
          Adds download links and CI configuration to publish the macOS app as a
          standalone package.
        </ChangeItem>
        <ChangeItem pull="7344">
          The macOS app now uses a System Extension instead of an App Extension
          for tunneling. This is needed for the app to be distributed outside of
          the Mac App Store.
        </ChangeItem>
        <ChangeItem pull="7594">
          Fixes a race condition that could cause the app to crash in rare
          circumstances if the VPN profile is removed from system settings while
          the app is running.
        </ChangeItem>
        <ChangeItem pull="7593">
          Fixes a bug where the VPN status would not properly update upon the
          first launch of the app.
        </ChangeItem>
        <ChangeItem pull="7334">
          Fixes an issue where certain NAT types would cause excessive signaling
          traffic which led to connectivity issues.
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
      <Entry version="1.3.9" date={new Date("2024-11-08")}>
        <ChangeItem pull="7288">
          Fixes an issue where network roaming would cause Firezone to become
          unresponsive.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.8" date={new Date("2024-11-05")}>
        <ChangeItem pull="7263">
          Mitigates a crash in case the maximum packet size is not respected.
        </ChangeItem>
        <ChangeItem pull="7265">
          Prevents re-connections to the portal from hanging for longer than 5s.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.7" date={new Date("2024-10-31")}>
        <ChangeItem>Handles DNS queries over TCP correctly.</ChangeItem>
        <ChangeItem pull="7152">
          Adds always-on error reporting using sentry.io.
        </ChangeItem>
        <ChangeItem pull="7164">
          Fixes an issue where Firezone would fail to establish connections to
          Gateways and the user had to sign-out and in again.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.6" date={new Date("2024-10-02")}>
        <ChangeItem pull="6831">
          Ensures Firefox doesn&apos;t attempt to use DNS over HTTPS when
          Firezone is active.
        </ChangeItem>
        <ChangeItem pull="6845">
          Fixes connectivity issues on idle connections by entering an
          always-on, low-power mode instead of closing them.
        </ChangeItem>
        <ChangeItem pull="6857">
          MacOS: sends hardware&apos;s UUID for device verification.
        </ChangeItem>
        <ChangeItem pull="6857">
          iOS: sends Id for vendor for device verification.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.5" date={new Date("2024-09-26")}>
        <ChangeItem pull="6809">
          Fixes a bug where non-wildcard DNS resources were not prioritised over
          wildcard ones (e.g. <code>app.example.com</code> vs{" "}
          <code>*.example.com</code>).
        </ChangeItem>
      </Entry>
      <Entry version="1.3.4" date={new Date("2024-09-25")}>
        <ChangeItem pull="6788">
          Fixes an issue where some browsers may fail to route DNS Resources
          correctly.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.3" date={new Date("2024-09-19")}>
        <ChangeItem pull="6765">
          Fixes a bug where DNS PTR queries by the system did not get answered.
        </ChangeItem>
        <ChangeItem pull="6722">
          Fixes a routing bug when one of several overlapping CIDR resources
          gets disabled / removed.
        </ChangeItem>
        <ChangeItem>
          Improves logging for DNS queries when{" "}
          <code>firezone_tunnel=trace</code> log level is used.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.2" date={new Date("2024-09-18")}>
        <ChangeItem pull="6632">
          (macOS) Fixes a bug where the addressDescription wasn&apos;t fully
          displayed in the macOS menu bar if it exceeded a certain length.
        </ChangeItem>
        <ChangeItem pull="6679">
          (macOS) Displays a notification when a new version is available.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.1" date={new Date("2024-09-05")}>
        <ChangeItem pull="6521">
          Gracefully handles cases where the device&apos;s local interface
          IPv4/IPv6 address or local network gateway changes while the client is
          connected.
        </ChangeItem>
        <ChangeItem pull="6518">
          Minor improvements to the look of the internet resource and makes the
          Internet resource off by default.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.0" date={new Date("2024-08-30")}>
        <ChangeItem pull="6434">Adds the Internet Resource feature.</ChangeItem>
      </Entry>
      <Entry version="1.2.1" date={new Date("2024-08-22")}>
        <ChangeItem pull="6406">
          Shows the Git SHA corresponding to the build on the Settings -&gt;
          Advanced screen.
        </ChangeItem>
        <ChangeItem pull="6424">
          Fixes a bug where packets would be lost when a connection is first
          established to a Gateway due to routes being updated with no actual
          change.
        </ChangeItem>
      </Entry>
      <Entry version="1.2.0" date={new Date("2024-08-21")}>
        <ChangeItem pull="5901">
          Implements glob-like matching of domains for DNS resources.
        </ChangeItem>
        <ChangeItem pull="6186">
          Adds the ability to mark Resources as favorites.
        </ChangeItem>
        <ChangeItem pull="6361">
          Connections to Gateways are now sticky for the duration of the
          Client&apos;s session. This fixes potential issues maintaining
          long-lived TCP connections to Gateways in a high-availability setup.
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
      <Entry version="1.1.4" date={new Date("2024-08-10")}>
        <ChangeItem pull="6181">
          Improves reliability of DNS resolution of non-resources.
        </ChangeItem>
      </Entry>
      <Entry version="1.1.3" date={new Date("2024-08-02")}>
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
      <Entry version="1.1.2" date={new Date("2024-07-03")}>
        <li className="pl-2">
          Prevents Firezone&apos;s stub resolver from intercepting DNS record
          types besides A, AAAA, and PTR. These are now forwarded to your
          upstream DNS resolver.
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
        <p>
          <strong>Note:</strong> Client versions 1.1.x are incompatible with
          Gateways running 1.0.x.
        </p>
      </Entry>
      <Entry version="1.0.5" date={new Date("2024-06-13")}>
        This release introduces new Resource status updates in the Resource
        list.
      </Entry>
      <Entry version="1.0.4" date={new Date("2024-05-01")}>
        Bug fixes.
      </Entry>
      <Entry version="1.0.3" date={new Date("2024-04-28")}>
        Bug fixes.
      </Entry>
      <Entry version="1.0.2" date={new Date("2024-04-24")}>
        Bug fixes.
      </Entry>
      <Entry version="1.0.1" date={new Date("2024-04-04")}>
        Bug fixes.
      </Entry>
      <Entry version="1.0.0" date={new Date("2024-04-01")}>
        Initial release.
      </Entry>
    </Entries>
  );
}
