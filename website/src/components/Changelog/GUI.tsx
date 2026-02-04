import Entry from "./Entry";
import Entries, { DownloadLink } from "./Entries";
import ChangeItem from "./ChangeItem";
import Unreleased from "./Unreleased";
import { OS } from ".";
import Link from "next/link";
import { Route } from "next";

export default function GUI({ os }: { os: OS }) {
  return (
    <Entries downloadLinks={downloadLinks(os)} title={title(os)}>
      {/* When you cut a release, remove any solved issues from the "known issues" lists over in `client-apps`. This must not be done when the issue's PR merges. */}
      <Unreleased></Unreleased>
      <Entry version="1.5.10" date={new Date("2026-02-02")}>
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
        {os == OS.Linux && (
          <ChangeItem pull="11813">
            Fixes an issue where notifications would not always be displayed.
          </ChangeItem>
        )}
        <ChangeItem pull="11891">
          Fixes an issue where cached IPv6 addresses for a resource got returned
          for IPv4-only DNS resources if the setting was only changed after a
          DNS query had already been processed.
        </ChangeItem>
      </Entry>
      <Entry version="1.5.9" date={new Date("2025-12-23")}>
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
        {os == OS.Linux && (
          <ChangeItem pull="10849">
            Fixes some rendering issues on Wayland-only systems.
          </ChangeItem>
        )}
        <ChangeItem pull="10914">
          Fixes an issue where concurrent DNS queries with the same ID would be
          dropped.
        </ChangeItem>
        <ChangeItem pull="11115">
          Fixes an issue where Firezone would not connect if an IPv6 interface
          is present but not routable.
        </ChangeItem>
        {os == OS.Linux && (
          <ChangeItem pull="11243">
            Fixes an issue where upgrading from version 1.5.8 on Fedora fails
            due to a bad scriptlet. To uninstall version 1.5.8, use{" "}
            <code>
              sudo dnf remove firezone-client-gui --setopt=tsflags=noscripts
            </code>
          </ChangeItem>
        )}
      </Entry>
      <Entry version="1.5.8" date={new Date("2025-10-16")}>
        <ChangeItem pull="10509">
          Fixes an issue where the Internet Resource could be briefly active on
          startup, despite it being disabled.
        </ChangeItem>
        <ChangeItem pull="10533">
          Improves reliability by caching DNS responses as per their TTL.
        </ChangeItem>
        {os == OS.Linux && (
          <ChangeItem pull="10539">
            Fixes an issue where the Tunnel Service was not running after a
            version upgrade.
          </ChangeItem>
        )}
        {os == OS.Linux && (
          <ChangeItem pull="10554">
            Fixes an issue where local LAN traffic was dropped when the Internet
            Resource was active.
          </ChangeItem>
        )}
      </Entry>
      <Entry version="1.5.7" date={new Date("2025-09-10")}>
        <ChangeItem pull="10104">
          {
            "Fixes an issue where DNS resources would resolve to a different IP after signing out and back into Firezone. This would break connectivity for long-running services that don't re-resolve DNS, like SSH sessions or mongoose."
          }
        </ChangeItem>
      </Entry>
      <Entry version="1.5.6" date={new Date("2025-07-28")}>
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
      <Entry version="1.5.5" date={new Date("2025-07-09")}>
        <ChangeItem pull="9779">Fixes a rare crash during sign-in.</ChangeItem>
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
      <Entry version="1.5.4" date={new Date("2025-06-19")}>
        <ChangeItem pull="9564">
          Fixes an issue where connections would fail to establish if both
          Client and Gateway were behind symmetric NAT.
        </ChangeItem>
      </Entry>
      <Entry version="1.5.3" date={new Date("2025-06-16")}>
        <ChangeItem pull="9537">
          Fixes an issue that caused increased CPU and memory consumption.
        </ChangeItem>
      </Entry>
      <Entry version="1.5.2" date={new Date("2025-06-12")}>
        <ChangeItem pull="8160">
          Moves network change listening to the tunnel service for improved
          reliability.
        </ChangeItem>
        <ChangeItem pull="9505">
          Fixes minor visual inconsistencies in the main app window.
        </ChangeItem>
        <ChangeItem pull="9443">
          Fixes an issue where log directives applied via MDM would not be
          applied on startup.
        </ChangeItem>
        <ChangeItem pull="9445">
          Fixes an issue where disabling the update checker via MDM would cause
          the Client to hang upon sign-in.
        </ChangeItem>
        <ChangeItem pull="9477">
          Fixes an issue where disabling &quot;connect on start&quot; would
          incorrectly show the Client as &quot;Signed in&quot; on the next
          launch.
        </ChangeItem>
      </Entry>
      <Entry version="1.5.1" date={new Date("2025-06-05")}>
        <ChangeItem pull="9418">
          Fixes an issue where advanced settings were not saved and loaded
          properly across restarts of the Client.
        </ChangeItem>
      </Entry>
      <Entry version="1.5.0" date={new Date("2025-06-05")}>
        <ChangeItem pull="9300">
          Uses the new IP stack setting for DNS resources, which allows DNS
          resources to optionally return only A or AAAA records if configured by
          the administrator.
        </ChangeItem>
        <ChangeItem pull="9211">
          Fixes an issue where changing the Advanced settings would reset the
          favourited resources.
        </ChangeItem>
        {os === OS.Windows && (
          <ChangeItem pull="9203">
            Allows managing certain settings via an MDM provider such as
            Microsoft Intune. For more details on how to do this, see the{" "}
            <Link
              href={"/kb/deploy/clients#provision-with-mdm" as Route}
              className="text-accent-500 underline hover:no-underline"
            >
              the knowledge base article
            </Link>
            .
          </ChangeItem>
        )}
        <ChangeItem pull="9366">
          Fixes an issue where Firezone could not start if the operating system
          refused our request to increase the UDP socket buffer sizes.
        </ChangeItem>
        <ChangeItem pull="9381">
          Introduces &quot;General&quot; settings, allowing the user to manage
          autostart behaviour as well as the to-be-used account slug.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.14" date={new Date("2025-05-21")}>
        <ChangeItem pull="9147">
          Fixes an issue where connections failed to establish on machines with
          multiple valid egress IPs.
        </ChangeItem>
        <ChangeItem pull="9136">
          Launching Firezone while it is already running while now re-activate
          the &quot;Welcome&quot; screen, allowing the user to sign in and out.
        </ChangeItem>
        {os === OS.Windows && (
          <ChangeItem pull="9154">
            Renames the background service from{" "}
            <code>FirezoneClientIpcService</code>
            to <code>FirezoneClientTunnelService</code>.
          </ChangeItem>
        )}
        {os === OS.Linux && (
          <ChangeItem pull="9154">
            Renames the systemd service from{" "}
            <code>firezone-client-ipc.service</code> to
            <code>firezone-client-tunnel.service</code>.
          </ChangeItem>
        )}
        {os === OS.Linux && (
          <ChangeItem pull="9181">
            Increases minimum supported CentOS version to 10.
          </ChangeItem>
        )}
        {os === OS.Windows && (
          <ChangeItem pull="9213">
            Adds the Client to the winget repository. You can install it via
            <code>winget install Firezone.Client.GUI</code>.
          </ChangeItem>
        )}
      </Entry>
      <Entry version="1.4.13" date={new Date("2025-05-14")}>
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
          <ChangeItem pull="9112">
            Fixes a rare crash that could occur if the tray menu cannot be
            initialised.
          </ChangeItem>
        )}
        <ChangeItem pull="9093">
          Fixes a rare panic when the DNS servers on the system would change
          while Firezone is connected.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.12" date={new Date("2025-04-30")}>
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
        <ChangeItem pull="8926">
          Rolls over to a new log-file as soon as logs are cleared.
        </ChangeItem>
        <ChangeItem pull="8935">
          Improves reliability for upload-intensive connections with many
          concurrent DNS queries.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.11" date={new Date("2025-04-21")}>
        <ChangeItem pull="8798">
          Improves performance of relayed connections on IPv4-only systems.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.10" date={new Date("2025-04-15")}>
        {os === OS.Linux && (
          <ChangeItem pull="8754">
            Fixes a performance regression that could lead to packet drops under
            high load.
          </ChangeItem>
        )}
        <ChangeItem pull="7590">
          Improves performance by moving UDP sockets to a dedicated thread.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.9" date={new Date("2025-03-14")}>
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
      <Entry version="1.4.8" date={new Date("2025-03-10")}>
        <ChangeItem pull="8286">
          Fixes a bug that prevented certain Resource fields from being updated
          when they were updated in the admin portal.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.7" date={new Date("2025-02-26")}>
        {os === OS.Linux && (
          <ChangeItem pull="8219">
            Configures the IPC service to log to journald.
          </ChangeItem>
        )}
        {os === OS.Windows && (
          <ChangeItem pull="8268">
            Fixes a hang that could occur after signing out which could prevent
            future sign ins and other actions, possibly with an{" "}
            <code>os error 231</code> code.
          </ChangeItem>
        )}
      </Entry>
      <Entry version="1.4.6" date={new Date("2025-02-20")}>
        {os === OS.Linux && (
          <ChangeItem pull="8117">
            Fixes an upload speed performance regression.
          </ChangeItem>
        )}
        <ChangeItem pull="8129">
          Allows signing-in without access to the local keyring.
        </ChangeItem>
        {os === OS.Windows && (
          <ChangeItem pull="8156">
            Fixes a race condition that attempted to remove the WinTUN adapter
            twice upon shutdown.
          </ChangeItem>
        )}
      </Entry>
      <Entry version="1.4.5" date={new Date("2025-02-12")}>
        <ChangeItem pull="8105">
          Fixes a visual regression where the Settings and About window lost
          their styling attributes.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.4" date={new Date("2025-02-11")}>
        <ChangeItem pull="8035">
          Shows a non-disruptive toast notification and quits the GUI client in
          case the IPC service gets shut down through the service manager.
        </ChangeItem>
        {os === OS.Windows && (
          <ChangeItem pull="8083">
            Fixes a regression introduced in 1.4.3 where Firezone would not work
            on systems with a disabled IPv6 stack.
          </ChangeItem>
        )}
      </Entry>
      <Entry version="1.4.3" date={new Date("2025-02-05")}>
        {os === OS.Windows && (
          <ChangeItem pull="8003">
            Removes dependency on <code>netsh</code>, making sign-in faster.
          </ChangeItem>
        )}
        {os === OS.Windows && (
          <ChangeItem pull="7972">
            Makes DNS configuration more resilient.
          </ChangeItem>
        )}
      </Entry>
      <Entry version="1.4.2" date={new Date("2025-01-30")}>
        {os === OS.Windows && (
          <ChangeItem pull="7912">
            Fixes an issue where the tunnel device could not be created,
            resulting in an immediate sign-out after signing-in.
          </ChangeItem>
        )}
      </Entry>
      <Entry version="1.4.1" date={new Date("2025-01-28")}>
        <ChangeItem pull="7551">
          Fixes an issue where large DNS responses were incorrectly discarded.
        </ChangeItem>
        {os === OS.Windows && (
          <ChangeItem pull="7556">
            Disables URO/GRO due to hardware / driver bugs.
          </ChangeItem>
        )}
        {os === OS.Linux && (
          <ChangeItem pull="7822">
            Makes the runtime dependency on <code>update-desktop-database</code>{" "}
            optional, thus improving compatibility on non-Ubuntu systems.
          </ChangeItem>
        )}
      </Entry>
      <Entry version="1.4.0" date={new Date("2024-12-13")}>
        <ChangeItem pull="7210">
          Adds support for GSO (Generic Segmentation Offload), delivering
          throughput improvements of up to 60%.
        </ChangeItem>
        <ChangeItem>
          Makes use of the new control protocol, delivering faster and more
          robust connection establishment.
        </ChangeItem>
        {os === OS.Linux && (
          <ChangeItem pull="7449">
            Uses multiple threads to read & write to the TUN device, greatly
            improving performance.
          </ChangeItem>
        )}
        <ChangeItem pull="7477">
          Improves connection setup latency by buffering initial packets.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.13" date={new Date("2024-11-15")}>
        <ChangeItem pull="7334">
          Fixes an issue where symmetric NATs would generate unnecessary
          candidate for hole-punching.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.12" date={new Date("2024-11-08")}>
        <ChangeItem pull="7288">
          Fixes an issue where network roaming would cause Firezone to become
          unresponsive.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.11" date={new Date("2024-11-05")}>
        <ChangeItem pull="7263">
          Mitigates a crash in case the maximum packet size is not respected.
        </ChangeItem>
        <ChangeItem pull="7265">
          Prevents re-connections to the portal from hanging for longer than 5s.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.10" date={new Date("2024-10-31")}>
        <ChangeItem>Handles DNS queries over TCP correctly.</ChangeItem>
        {os === OS.Windows && (
          <ChangeItem pull="7009">
            The IPC service <code>firezone-client-ipc.exe</code> is now signed.
          </ChangeItem>
        )}
        <ChangeItem pull="7123">
          Reports the version to the Portal correctly.
        </ChangeItem>
        {os === OS.Linux && (
          <ChangeItem pull="6996">
            Supports Ubuntu 24.04, no longer supports Ubuntu 20.04.
          </ChangeItem>
        )}
        <ChangeItem pull="7164">
          Fixes an issue where Firezone would fail to establish connections to
          Gateways and the user had to sign-out and in again.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.9" date={new Date("2024-10-09")}>
        {os === OS.Linux && (
          <ChangeItem pull="6987">
            Fixes a crash on startup caused by incorrect permissions on the ID
            file.
          </ChangeItem>
        )}
      </Entry>
      <Entry version="1.3.8" date={new Date("2024-10-08")}>
        <ChangeItem pull="6874">Fixes the GUI shutting down slowly.</ChangeItem>
        {os === OS.Windows && (
          <ChangeItem pull="6931">
            {"Mitigates an issue where "}
            <code>ipconfig</code>
            {
              " and WSL weren't aware of Firezone DNS resolvers. Users may need to restart WSL after signing in to Firezone."
            }
          </ChangeItem>
        )}
      </Entry>
      <Entry version="1.3.7" date={new Date("2024-10-02")}>
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
        {os === OS.Windows && (
          <ChangeItem pull="6874">
            Fixes a delay when closing the GUI.
          </ChangeItem>
        )}
        <ChangeItem pull="6857">
          {"Tries to send motherboard's hardware ID for device verification."}
        </ChangeItem>
      </Entry>
      <Entry version="1.3.6" date={new Date("2024-09-25")}>
        <ChangeItem pull="6809">
          Fixes a bug where non-wildcard DNS resources were not prioritised over
          wildcard ones (e.g. <code>app.example.com</code> vs{" "}
          <code>*.example.com</code>).
        </ChangeItem>
      </Entry>
      <Entry version="1.3.5" date={new Date("2024-09-25")}>
        <ChangeItem pull="6788">
          Fixes an issue where some browsers may fail to route DNS Resources
          correctly.
        </ChangeItem>
        {os === OS.Linux && (
          <ChangeItem pull="6780">
            {
              "Fixes a bug where the Linux Clients didn't work on ZFS filesystems."
            }
          </ChangeItem>
        )}
        <ChangeItem pull="6795">
          {
            'Fixes a bug where auto-sign-in with an expired token would cause a "Couldn\'t send Disconnect" error message.'
          }
        </ChangeItem>
        {os === OS.Windows && (
          <ChangeItem pull="6810">
            Fixes a bug where roaming from Ethernet to WiFi would cause Firezone
            to fail to connect to the portal.
          </ChangeItem>
        )}
      </Entry>
      <Entry version="1.3.4" date={new Date("2024-09-19")}>
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
      <Entry version="1.3.3" date={new Date("2024-09-13")}>
        {os === OS.Windows && (
          <ChangeItem pull="6681">
            Fixes a bug where sign-in fails if IPv6 is disabled.
          </ChangeItem>
        )}
      </Entry>
      <Entry version="1.3.2" date={new Date("2024-09-06")}>
        <ChangeItem pull="6624">
          Fixes a bug that took down the tunnel when internet resource was
          missing.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.1" date={new Date("2024-09-05")}>
        <ChangeItem pull="6518">
          Minor improvements to the look of the internet resource and makes the
          Internet resource off by default.
        </ChangeItem>
        <ChangeItem pull="6584">
          Prevents routing loops for some Windows installation when the Internet
          resource was on, taking down network connections.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.0" date={new Date("2024-08-30")}>
        <ChangeItem pull="6434">Adds the Internet Resource feature.</ChangeItem>
      </Entry>
      <Entry version="1.2.2" date={new Date("2024-08-29")}>
        <ChangeItem pull="6432">
          Shows an orange dot on the tray icon when an update is ready to
          download.
        </ChangeItem>
        <ChangeItem pull="6449">Checks for updates once a day</ChangeItem>
        {os === OS.Windows && (
          <ChangeItem pull="6472">
            {
              "Fixes an issue where Split DNS didn't work for domain-joined Windows machines"
            }
          </ChangeItem>
        )}
      </Entry>
      <Entry version="1.2.1" date={new Date("2024-08-27")}>
        <ChangeItem pull="6414">
          {
            "Waits for Internet to connect to Firezone if there's no Internet at startup and you're already signed in."
          }
        </ChangeItem>
        <ChangeItem pull="6455">
          Fixes a false positive warning log at startup about DNS interception
          being disabled.
        </ChangeItem>
        <ChangeItem pull="6458">
          Fixes a bug where we considered our own startup to be a network change
          event, which may interfere with access to DNS Resources.
        </ChangeItem>
      </Entry>
      <Entry version="1.2.0" date={new Date("2024-08-21")}>
        <ChangeItem pull="5901">
          Implements glob-like matching of domains for DNS resources.
        </ChangeItem>
        {os === OS.Windows && (
          <ChangeItem pull="6280">
            Fixes a bug where the &quot;Clear Logs&quot; button did not clear
            the IPC service logs.
          </ChangeItem>
        )}
        {os === OS.Windows && (
          <ChangeItem pull="6308">
            Fixes a bug where the GUI could not run if the user is Administrator
          </ChangeItem>
        )}
        <ChangeItem pull="6351">
          The log filter on the IPC service is now reloaded immediately when you
          change the setting in the GUI.
        </ChangeItem>
        <ChangeItem pull="6361">
          {
            "Connections to Gateways are now sticky for the duration of the Client's session to fix issues with long-lived TCP connections."
          }
        </ChangeItem>
      </Entry>
      <Entry version="1.1.12" date={new Date("2024-08-13")}>
        <ChangeItem pull="6226">
          Fixes a bug where clearing the log files would delete the current
          logfile, preventing logs from being written.
        </ChangeItem>
        <ChangeItem pull="6276">
          Fixes a bug where relayed connections failed to establish after an
          idle period.
        </ChangeItem>
        <ChangeItem pull="6277">
          Fixes a bug where restrictive NATs caused connectivity problems.
        </ChangeItem>
      </Entry>
      <Entry version="1.1.11" date={new Date("2024-08-09")}>
        <ChangeItem pull="6233">
          Fixes an issue where the IPC service can panic during DNS resolution.
        </ChangeItem>
      </Entry>
      <Entry version="1.1.10" date={new Date("2024-08-08")}>
        <ChangeItem pull="5923">
          Adds the ability to mark Resources as favorites.
        </ChangeItem>
        {os === OS.Linux && (
          <ChangeItem pull="6163">
            Supports using <code>etc-resolv-conf</code> DNS control method, or
            disabling DNS control
          </ChangeItem>
        )}
        <ChangeItem pull="6181">
          Improves reliability of DNS resolution of non-resources.
        </ChangeItem>
        {os === OS.Windows && (
          <ChangeItem pull="6163">Supports disabling DNS control</ChangeItem>
        )}
        <ChangeItem pull="6184">
          Mitigates a bug where the IPC service can panic if an internal channel
          fills up
        </ChangeItem>
      </Entry>
      <Entry version="1.1.9" date={new Date("2024-08-02")}>
        <ChangeItem pull="6143">
          Fixes an issue where DNS queries could time out on some networks.
        </ChangeItem>
      </Entry>
      <Entry version="1.1.8" date={new Date("2024-08-01")}>
        {os === OS.Linux && (
          <ChangeItem pull="5978">Adds network roaming support.</ChangeItem>
        )}
        {os === OS.Windows && (
          <ChangeItem pull="6051">
            Fixes &quot;Element not found&quot; error when setting routes.
          </ChangeItem>
        )}
        <ChangeItem pull="6017">
          Removes keyboard accelerators, which were not working.
        </ChangeItem>
        <ChangeItem pull="6071">
          Puts angle brackets around hyperlinks in the menu.
        </ChangeItem>
      </Entry>
      <Entry version="1.1.7" date={new Date("2024-07-17")}>
        {os === OS.Linux && (
          <ChangeItem pull="5848">
            Stops the GUI and prompts you to re-launch it if you update Firezone
            while the GUI is running.
          </ChangeItem>
        )}
        {os === OS.Windows && (
          <ChangeItem pull="5375">
            Improves sign-in speed and fixes a DNS leak
          </ChangeItem>
        )}
      </Entry>
      <Entry version="1.1.6" date={new Date("2024-07-12")}>
        <ChangeItem pull="5795">
          Unexpected IPC service stops are now reported as &quot;IPC connection
          closed&quot;.
        </ChangeItem>
        {os === OS.Windows && (
          <ChangeItem pull="5827">
            Fixes a bug where DNS could stop working when you sign out.
          </ChangeItem>
        )}
        <ChangeItem pull="5817">
          Shows different tray icons when signed out, signing in, and signed in.
        </ChangeItem>
      </Entry>
      <Entry version="1.1.5" date={new Date("2024-07-08")}>
        {os === OS.Linux && (
          <ChangeItem pull="5793">
            The Linux GUI Client is now built for both x86-64 and ARM64.
          </ChangeItem>
        )}
      </Entry>
      <Entry version="1.1.4" date={new Date("2024-07-05")}>
        <ChangeItem pull="5700">
          Fixes an issue where a stale DNS cache could prevent traffic from
          routing to DNS Resources if they were updated while the Client was
          signed in.
        </ChangeItem>
      </Entry>
      <Entry version="1.1.3" date={new Date("2024-07-03")}>
        <li className="pl-2">
          {
            "Prevents Firezone's stub resolver from intercepting DNS record types besides A, AAAA, and PTR. These are now forwarded to your upstream DNS resolver."
          }
        </li>
      </Entry>
      <Entry version="1.1.2" date={new Date("2024-06-29")}>
        <li className="pl-2">
          Fixes an issue that could cause Resources to be unreachable a few
          hours after roaming networks.
        </li>
        <li className="pl-2">
          Reduces noise in logs for the default log level.
        </li>
        {os === OS.Windows && (
          <li className="pl-2">
            Substantially reduces memory usage for the IPC service.
          </li>
        )}
      </Entry>
      <Entry version="1.1.1" date={new Date("2024-06-27")}>
        {os === OS.Windows ? (
          <p>This release fixes a performance issue.</p>
        ) : (
          <p>This is a maintenance release with no user-facing changes.</p>
        )}
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
        {os === OS.Windows && (
          <li className="pl-2">
            Fixes a hang that could occur when the Client is quit, preventing it
            from opening again.
          </li>
        )}
        <p>
          <strong>Note:</strong> Client versions 1.1.x are incompatible with
          Gateways running 1.0.x.
        </p>
      </Entry>
      <Entry version="1.0.9" date={new Date("2024-06-18")}>
        This release simplifies the Resource connected state icons in the menu
        to prevent issues with certain Linux distributions.
      </Entry>
      <Entry version="1.0.8" date={new Date("2024-06-17")}>
        Fixes an issue in Windows that could cause the Wintun Adapter to fail to
        be created under certain conditions.
      </Entry>
      <Entry version="1.0.7" date={new Date("2024-06-12")}>
        This release fixes a bug where the incorrect Client version was reported
        to the admin portal.
      </Entry>
      <Entry version="1.0.6" date={new Date("2024-06-11")}>
        This release contains connectivity fixes and performance improvements
        and is recommended for all users.
      </Entry>
      <Entry version="1.0.5" date={new Date("2024-05-22")}>
        This release adds an IPC service for Windows to allow for better process
        isolation.
      </Entry>
      <Entry version="1.0.4" date={new Date("2024-05-14")}>
        This release fixes a bug on Windows where system DNS could break after
        the Firezone Client was closed.
      </Entry>
      <Entry version="1.0.3" date={new Date("2024-05-08")}>
        Maintenance release.
      </Entry>
      <Entry version="1.0.2" date={new Date("2024-04-30")}>
        This release reverts a change that could cause connectivity issues seen
        by some users.
      </Entry>
      <Entry version="1.0.1" date={new Date("2024-04-29")}>
        Update the upgrade URLs used to check for new versions.
      </Entry>
      <Entry version="1.0.0" date={new Date("2024-04-24")}>
        Initial release.
      </Entry>
    </Entries>
  );
}

function downloadLinks(os: OS): DownloadLink[] {
  switch (os) {
    case OS.Windows:
      return [
        {
          title: "Download for x86_64",
          href: "/dl/firezone-client-gui-windows/:version/x86_64",
        },
      ];
    case OS.Linux:
      return [
        {
          title: "Download for x86_64",
          href: "/dl/firezone-client-gui-linux/:version/x86_64",
        },
        {
          title: "Download for aarch64",
          href: "/dl/firezone-client-gui-linux/:version/aarch64",
        },
      ];
  }
}

function title(os: OS): string {
  switch (os) {
    case OS.Windows:
      return "Windows GUI";
    case OS.Linux:
      return "Linux GUI";
  }
}
