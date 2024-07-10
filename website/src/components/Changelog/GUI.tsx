import Link from "next/link";
import Entry from "./Entry";
import Entries from "./Entries";

export default function GUI({ title }: { title: string }) {
  const href =
    title === "Windows"
      ? "/dl/firezone-client-gui-windows/:version/:arch"
      : "/dl/firezone-client-gui-linux/:version/:arch";
  const arches = title === "Windows" ? ["x86_64"] : ["x86_64", "aarch64"];

  return (
    <Entries href={href} arches={arches} title={title}>
      {/*<Entry version="1.1.6" date={new Date("2024-07-10")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          {title === "Linux GUI" && (
          <li className="pl-2">
            <p>This is a maintenance release with no user-facing changes.</p>
          </li>
          )}
          {title === "Windows" && (
          <li className="pl-2">
            Fixes{" "}
            <Link
              href="https://github.com/firezone/firezone/pull/5827"
              className="text-accent-500 underline hover:no-underline"
            >
              a bug where DNS could stop working when you sign out.
            </Link>
          </li>
          )}
        </ul>
      </Entry>*/}
      <Entry version="1.1.5" date={new Date("2024-07-08")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          {title === "Linux GUI" && (
          <li className="pl-2">
            The Linux GUI Client is now{" "}
            <Link
              href="https://github.com/firezone/firezone/pull/5793"
              className="text-accent-500 underline hover:no-underline"
            >
              built for both x86-64 and ARM64
            </Link>
          </li>
          )}
          {title === "Windows" && (
            <li className="pl-2">
              <p>This is a maintenance release with no user-facing changes.</p>
            </li>
          )}
        </ul>
      </Entry>
      <Entry version="1.1.4" date={new Date("2024-07-05")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
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
