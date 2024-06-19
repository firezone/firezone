import Entries from "./Entries";
import Entry from "./Entry";
import Wrapper from "./Wrapper";

export default function Android() {
  return (
    <Wrapper
      title="Android"
      version="1.0.4"
      date={new Date("2024-06-13")}
      notes={
        <>
          This release fixes a bug where the incorrect Client version could be
          reported to the admin portal.
        </>
      }
    >
      <Entries>
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
    </Wrapper>
  );
}
