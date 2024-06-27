import Entries from "./Entries";
import Entry from "./Entry";

export default function Android() {
  return (
    <Entries title="Android">
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
