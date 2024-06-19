import Entry from "./Entry";
import Entries from "./Entries";
import Link from "next/link";

export default function Gateway() {
  return (
    <Entries title="Gateway">
      <Entry version="1.0.8" date={new Date("2024-06-17")}>
        This is a maintenance release with no major user-facing changes.
      </Entry>
      <Entry version="1.0.7" date={new Date("2024-06-12")}>
        This release fixes a bug where the incorrect Gateway version could be
        reported to the admin portal.
      </Entry>
      <Entry version="1.0.6" date={new Date("2024-06-11")}>
        This release contains connectivity fixes and performance improvements
        and is recommended for all users.
      </Entry>
      <Entry version="1.0.5" date={new Date("2024-05-22")}>
        Minor maintenance fixes.
      </Entry>
      <Entry version="1.0.4" date={new Date("2024-05-14")}>
        Fixes an issue detecting the correct architecture during installation
        and upgrades.
      </Entry>
      <Entry version="1.0.3" date={new Date("2024-05-08")}>
        Adds support for{" "}
        <Link
          href="/kb/deploy/resources#traffic-restrictions"
          className="hover:underline text-accent-500"
        >
          traffic restrictions
        </Link>
        .
      </Entry>
      <Entry version="1.0.2" date={new Date("2024-04-30")}>
        Fixes a big that caused invalid connections from being cleaned up
        properly.
      </Entry>
      <Entry version="1.0.1" date={new Date("224-04-29")}>
        Fixes a bug that could prevent the auto-upgrade script from working
        properly.
      </Entry>
      <Entry version="1.0.0" date={new Date("2024-04-24")}>
        Initial release.
      </Entry>
    </Entries>
  );
}
