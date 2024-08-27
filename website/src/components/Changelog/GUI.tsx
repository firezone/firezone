import Link from "next/link";
import Entry from "./Entry";
import Entries from "./Entries";
import ChangeItem from "./ChangeItem";

export default function GUI({ title }: { title: string }) {
  const href =
    title === "Windows"
      ? "/dl/firezone-client-gui-windows/:version/:arch"
      : "/dl/firezone-client-gui-linux/:version/:arch";
  const arches = title === "Windows" ? ["x86_64"] : ["x86_64", "aarch64"];

  return (
    <Entries href={href} arches={arches} title={title}>
      {/* When you cut a release, remove any solved issues from the "known issues" lists over in `client-apps`. This cannot be done when the issue's PR merges. */}
      {/*
      <Entry version="1.2.1" date={new Date("")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          <ChangeItem pull="6414">
            Waits for Internet if there's no Internet at startup and you're already signed in
          </ChangeItem>
          <ChangeItem pull="6432">
            Shows an orange dot on the tray icon when an update is ready to download.
          </ChangeItem>
          <ChangeItem pull="6455">
            Fixes a false positive warning about DNS interception being disabled.
          </ChangeItem>
          <ChangeItem pull="6458">
            Fixes a bug where we considered our own startup to be a network change event.
          </ChangeItem>
        </ul>
      </Entry>
      */}
      <Entry version="1.2.0" date={new Date("2024-08-21")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          <ChangeItem pull="5901">
            Implements glob-like matching of domains for DNS resources.
          </ChangeItem>
          <ChangeItem enable={title === "Windows"} pull="6280">
            Fixes a bug where the "Clear Logs" button did not clear the IPC
            service logs.
          </ChangeItem>
          <ChangeItem enable={title === "Windows"} pull="6308">
            Fixes a bug where the GUI could not run if the user is Administrator
          </ChangeItem>
          <ChangeItem pull="6351">
            The log filter on the IPC service is now reloaded immediately when
            you change the setting in the GUI.
          </ChangeItem>
          <ChangeItem pull="6361">
            Connections to Gateways are now sticky for the duration of the
            Client's session to fix issues with long-lived TCP connections.
          </ChangeItem>
        </ul>
      </Entry>
      <Entry version="1.1.12" date={new Date("2024-08-13")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
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
        </ul>
      </Entry>
      <Entry version="1.1.11" date={new Date("2024-08-09")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          <ChangeItem pull="6233">
            Fixes an issue where the IPC service can panic during DNS
            resolution.
          </ChangeItem>
        </ul>
      </Entry>
      <Entry version="1.1.10" date={new Date("2024-08-08")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          <ChangeItem pull="5923">
            Adds the ability to mark Resources as favorites.
          </ChangeItem>
          <ChangeItem enable={title === "Linux GUI"} pull="6163">
            Supports using `etc-resolv-conf` DNS control method, or disabling
            DNS control
          </ChangeItem>
          <ChangeItem pull="6181">
            Improves reliability of DNS resolution of non-resources.
          </ChangeItem>
          <ChangeItem enable={title === "Windows"} pull="6163">
            Supports disabling DNS control
          </ChangeItem>
          <ChangeItem pull="6184">
            Mitigates a bug where the IPC service can panic if an internal
            channel fills up
          </ChangeItem>
        </ul>
      </Entry>
      <Entry version="1.1.9" date={new Date("2024-08-02")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          <ChangeItem pull="6143">
            Fixes an issue where DNS queries could time out on some networks.
          </ChangeItem>
        </ul>
      </Entry>
      <Entry version="1.1.8" date={new Date("2024-08-01")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          <ChangeItem enable={title === "Linux GUI"} pull="5978">
            Adds network roaming support.
          </ChangeItem>
          <ChangeItem enable={title === "Windows"} pull="6051">
            Fixes "Element not found" error when setting routes.
          </ChangeItem>
          <ChangeItem pull="6017">
            Removes keyboard accelerators, which were not working.
          </ChangeItem>
          <ChangeItem pull="6071">
            Puts angle brackets around hyperlinks in the menu.
          </ChangeItem>
        </ul>
      </Entry>
      <Entry version="1.1.7" date={new Date("2024-07-17")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          <ChangeItem enable={title === "Linux GUI"} pull="5848">
            Stops the GUI and prompts you to re-launch it if you update Firezone
            while the GUI is running.
          </ChangeItem>
          <ChangeItem enable={title === "Windows"} pull="5375">
            Improves sign-in speed and fixes a DNS leak
          </ChangeItem>
        </ul>
      </Entry>
      <Entry version="1.1.6" date={new Date("2024-07-12")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          <ChangeItem pull="5795">
            Unexpected IPC service stops are now reported as "IPC connection
            closed".
          </ChangeItem>
          <ChangeItem enable={title === "Windows"} pull="5827">
            Fixes a bug where DNS could stop working when you sign out.
          </ChangeItem>
          <ChangeItem pull="5817">
            Shows different tray icons when signed out, signing in, and signed
            in.
          </ChangeItem>
        </ul>
      </Entry>
      <Entry version="1.1.5" date={new Date("2024-07-08")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          <ChangeItem enable={title === "Linux GUI"} pull="5793">
            The Linux GUI Client is now built for both x86-64 and ARM64.
          </ChangeItem>
          <ChangeItem enable={title === "Windows"}>
            This is a maintenance release with no user-facing changes.
          </ChangeItem>
        </ul>
      </Entry>
      <Entry version="1.1.4" date={new Date("2024-07-05")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          <ChangeItem pull="5700">
            Fixes an issue where a stale DNS cache could prevent traffic from
            routing to DNS Resources if they were updated while the Client was
            signed in.
          </ChangeItem>
        </ul>
      </Entry>
      <Entry version="1.1.3" date={new Date("2024-07-03")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          <li className="pl-2">
            Prevents Firezone's stub resolver from intercepting DNS record types
            besides A, AAAA, and PTR. These are now forwarded to your upstream
            DNS resolver.
          </li>
        </ul>
      </Entry>
      <Entry version="1.1.2" date={new Date("2024-06-29")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          <li className="pl-2">
            Fixes an issue that could cause Resources to be unreachable a few
            hours after roaming networks.
          </li>
          <li className="pl-2">
            Reduces noise in logs for the default log level.
          </li>
          {title === "Windows" && (
            <li className="pl-2">
              Substantially reduces memory usage for the IPC service.
            </li>
          )}
        </ul>
      </Entry>
      <Entry version="1.1.1" date={new Date("2024-06-27")}>
        {title === "Windows" ? (
          <p>This release fixes a performance issue.</p>
        ) : (
          <p>This is a maintenance release with no user-facing changes.</p>
        )}
      </Entry>
      <Entry version="1.1.0" date={new Date("2024-06-27")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
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
          {title === "Windows" && (
            <li className="pl-2">
              Fixes a hang that could occur when the Client is quit, preventing
              it from opening again.
            </li>
          )}
        </ul>
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
