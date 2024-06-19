import Entry from "./Entry";
import Wrapper from "./Wrapper";
import Entries from "./Entries";

export default function Headless() {
  return (
    <Wrapper
      title="Linux headless"
      version="1.0.8"
      date={new Date("2024-06-17")}
      notes={
        <>This is a maintenance release with no major user-facing changes.</>
      }
    >
      <Entries>
        <Entry version="1.0.7" date={new Date("2024-06-12")}>
          This release fixes a bug where the incorrect Client version was
          reported to the admin portal.
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
          This release reverts a change that could cause connectivity issues
          seen by some users.
        </Entry>
        <Entry version="1.0.1" date={new Date("2024-04-29")}>
          Update the upgrade URLs used to check for new versions.
        </Entry>
        <Entry version="1.0.0" date={new Date("2024-04-24")}>
          Initial release.
        </Entry>
      </Entries>
    </Wrapper>
  );
}
