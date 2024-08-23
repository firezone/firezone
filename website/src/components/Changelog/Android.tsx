import ChangeItem from "./ChangeItem";
import Entries from "./Entries";
import Entry from "./Entry";
import Link from "next/link";

export default function Android() {
  return (
    <Entries
      href="https://play.google.com/store/apps/details?id=dev.firezone.android"
      title="Android"
    >
      {/*
      <Entry version="1.2.1" date={new Date(todo)}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          <ChangeItem pull="6424">
            Fixes a bug where packets would be lost when a connection is first
            established to a gateway, due to routes being updated with no actual
            change.
          </ChangeItem>
        </ul>
      </Entry>
      */}
      <Entry version="1.2.0" date={new Date("2024-08-21")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          <ChangeItem pull="5901">
            Implements glob-like matching of domains for DNS resources.
          </ChangeItem>
          <ChangeItem pull="6361">
            Connections to Gateways are now sticky for the duration of the
            Client's session. This fixes potential issues maintaining long-lived
            TCP connections to Gateways in a high-availability setup.
          </ChangeItem>
        </ul>
      </Entry>
      <Entry version="1.1.6" date={new Date("2024-08-13")}>
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
      <Entry version="1.1.5" date={new Date("2024-08-10")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          <ChangeItem pull="6107">
            Adds the ability to mark Resources as favorites.
          </ChangeItem>
          <ChangeItem pull="6181">
            Improves reliability of DNS resolution of non-resources.
          </ChangeItem>
        </ul>
      </Entry>
      <Entry version="1.1.4" date={new Date("2024-08-02")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
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
        </ul>
      </Entry>
      <Entry version="1.1.3" date={new Date("2024-07-06")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
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
          <li className="pl-2">Fixes various crashes.</li>
        </ul>
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
