import Entry from "./Entry";
import Entries, { DownloadLink } from "./Entries";
import ChangeItem from "./ChangeItem";
import Unreleased from "./Unreleased";
import { OS } from ".";

export default function GUI({ os }: { os: OS }) {
  return (
    <Entries downloadLinks={downloadLinks(os)} title={title(os)}>
      {/* When you cut a release, remove any solved issues from the "known issues" lists over in `client-apps`. This must not be done when the issue's PR merges. */}
      <Unreleased></Unreleased>
      <Entry version="1.4.5" date={new Date("2025-02-12")}>
        <ChangeItem pull="8105">
          Fixes a visual regression where the Settings and About window lost
          their styling attributes.
        </ChangeItem>
      </Entry>
      <Entry version="1.4.4" date={new Date("2025-02-11")}>
        <ChangeItem pull="8035">
          Shows a non-disruptive toast notification and quits the GUI client in
          case the IPC service gets shutdown through the service manager.
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
            Removes dependency on `netsh`, making sign-in faster.
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
            Makes the runtime dependency on `update-desktop-database` optional,
            thus improving compatibility on non-Ubuntu systems.
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
            The IPC service `firezone-client-ipc.exe` is now signed.
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
            Mitigates an issue where `ipconfig` and WSL weren't aware of
            Firezone DNS resolvers. Users may need to restart WSL after signing
            in to Firezone.
          </ChangeItem>
        )}
      </Entry>
      <Entry version="1.3.7" date={new Date("2024-10-02")}>
        <ChangeItem pull="6831">
          Ensures Firefox doesn't attempt to use DNS over HTTPS when Firezone is
          active.
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
          Tries to send motherboard's hardware ID for device verification.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.6" date={new Date("2024-09-25")}>
        <ChangeItem pull="6809">
          Fixes a bug where non-wildcard DNS resources were not prioritised over
          wildcard ones (e.g. `app.example.com` vs `*.example.com`).
        </ChangeItem>
      </Entry>
      <Entry version="1.3.5" date={new Date("2024-09-25")}>
        <ChangeItem pull="6788">
          Fixes an issue where some browsers may fail to route DNS Resources
          correctly.
        </ChangeItem>
        {os === OS.Linux && (
          <ChangeItem pull="6780">
            Fixes a bug where the Linux Clients didn't work on ZFS filesystems.
          </ChangeItem>
        )}
        <ChangeItem pull="6795">
          Fixes a bug where auto-sign-in with an expired token would cause a
          "Couldn't send Disconnect" error message.
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
            Fixes an issue where Split DNS didn't work for domain-joined Windows
            machines
          </ChangeItem>
        )}
      </Entry>
      <Entry version="1.2.1" date={new Date("2024-08-27")}>
        <ChangeItem pull="6414">
          Waits for Internet to connect to Firezone if there's no Internet at
          startup and you're already signed in.
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
            Fixes a bug where the "Clear Logs" button did not clear the IPC
            service logs.
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
          Connections to Gateways are now sticky for the duration of the
          Client's session to fix issues with long-lived TCP connections.
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
            Supports using `etc-resolv-conf` DNS control method, or disabling
            DNS control
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
            Fixes "Element not found" error when setting routes.
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
          Unexpected IPC service stops are now reported as "IPC connection
          closed".
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
          Prevents Firezone's stub resolver from intercepting DNS record types
          besides A, AAAA, and PTR. These are now forwarded to your upstream DNS
          resolver.
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
