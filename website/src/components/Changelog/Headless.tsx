import ChangeItem from "./ChangeItem";
import Entry from "./Entry";
import Entries from "./Entries";
import Link from "next/link";

export default function Headless() {
  const href = "/dl/firezone-client-headless-linux/:version/:arch";
  const arches = ["x86_64", "aarch64", "armv7"];

  return (
    <Entries href={href} arches={arches} title="Linux headless">
      {/* When you cut a release, remove any solved issues from the "known issues" lists over in `client-apps`. This must not be done when the issue's PR merges. */}
      {/*
      <Entry version="1.3.3" date={new Date(todo)}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          <ChangeItem pull="6782">
            Adds error reporting with sentry.io. Opt in using the environment variable `FIREZONE_ENABLE_TELEMETRY=1`
          </ChangeItem>
        </ul>
      </Entry>
      */}
      <Entry version="1.3.2" date={new Date("2024-09-25")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          <ChangeItem pull="6765">
            Fixes a bug where DNS PTR queries by the system did not get
            answered.
          </ChangeItem>
          <ChangeItem pull="6722">
            Fixes a routing bug when one of several overlapping CIDR resources
            gets disabled / removed.
          </ChangeItem>
          <ChangeItem pull="6780">
            Fixes a bug where the Linux Clients didn't work on ZFS filesystems.
          </ChangeItem>
          <ChangeItem pull="6788">
            Fixes an issue where some browsers may fail to route DNS Resources
            correctly.
          </ChangeItem>
        </ul>
      </Entry>
      <Entry version="1.3.1" date={new Date("2024-09-05")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          <ChangeItem pull="6563">
            Removes unnecessary packet buffers for a minor performance increase.
          </ChangeItem>
        </ul>
      </Entry>
      <Entry version="1.3.0" date={new Date("2024-08-30")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          <ChangeItem pull="6434">
            Adds the Internet Resource feature.
          </ChangeItem>
        </ul>
      </Entry>
      <Entry version="1.2.0" date={new Date("2024-08-21")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          <ChangeItem pull="5901">
            Implements glob-like matching of domains for DNS resources.
          </ChangeItem>
          <ChangeItem pull="6361">
            Connections to Gateways are now sticky for the duration of the
            Client's session to fix issues with long-lived TCP connections.
          </ChangeItem>
        </ul>
      </Entry>
      <Entry version="1.1.7" date={new Date("2024-08-13")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          <ChangeItem pull="6276">
            Fixes a bug where relayed connections failed to establish after an
            idle period.
          </ChangeItem>
          <ChangeItem pull="6277">
            Fixes a bug where restrictive NATs caused connectivity problems.
          </ChangeItem>
        </ul>
      </Entry>
      <Entry version="1.1.6" date={new Date("2024-08-09")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          <ChangeItem pull="6233">
            Fixes an issue where the IPC service can panic during DNS
            resolution.
          </ChangeItem>
        </ul>
      </Entry>
      <Entry version="1.1.5" date={new Date("2024-08-08")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          <ChangeItem pull="6163">
            Uses `systemd-resolved` DNS control by default on Linux
          </ChangeItem>
          <ChangeItem pull="6184">
            Mitigates a bug where the Client can panic if an internal channel
            fills up
          </ChangeItem>
          <ChangeItem pull="6181">
            Improves reliability of DNS resolution of non-resources.
          </ChangeItem>
        </ul>
      </Entry>
      <Entry version="1.1.4" date={new Date("2024-08-02")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          <ChangeItem pull="6143">
            Fixes an issue where DNS queries could time out on some networks.
          </ChangeItem>
        </ul>
      </Entry>
      <Entry version="1.1.3" date={new Date("2024-07-05")}>
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
      <Entry version="1.1.2" date={new Date("2024-07-03")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          <li className="pl-2">
            Prevents Firezone's stub resolver from intercepting DNS record types
            besides A, AAAA, and PTR. These are now forwarded to your upstream
            DNS resolver.
          </li>
        </ul>
      </Entry>
      <Entry version="1.1.1" date={new Date("2024-06-29")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          <li className="pl-2">
            Fixes an issue that could cause Resources to be unreachable a few
            hours after roaming networks.
          </li>
          <li className="pl-2">
            Reduces noise in logs for the default log level.
          </li>
        </ul>
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
        </ul>
        <p>
          <strong>Note:</strong> Client versions 1.1.x are incompatible with
          Gateways running 1.0.x.
        </p>
      </Entry>
      <Entry version="1.0.8" date={new Date("2024-06-17")}>
        This is a maintenance release with no major user-facing changes.
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
        This is a maintenance release with no major user-facing changes.
      </Entry>
      <Entry version="1.0.4" date={new Date("2024-05-14")}>
        This is a maintenance release with no major user-facing changes.
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
