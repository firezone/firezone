import Entries from "./Entries";
import Entry from "./Entry";

export default function Android() {
  return (
    <Entries title="Android">
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
