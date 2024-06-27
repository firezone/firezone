import Entry from "./Entry";
import Entries from "./Entries";

export default function Apple() {
  return (
    <Entries title="macOS / iOS">
      <Entry version="1.1.0" date={new Date("2024-06-27")}>
        <ul className="list-disc space-y-2 pl-4 mb-4">
          <li className="pl-2">
            Introduces the new DNS routing system supported by 1.1.0 Gateways
            which should result in much more stable connections for DNS
            Resources.
          </li>
          <li className="pl-2">
            Closes idle connections to Gateways that have not seen traffic for
            more than 5 minutes which can reduce power consumption when not
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
