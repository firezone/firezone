import Link from "next/link";
import Entry from "./Entry";
import Entries from "./Entries";
import ChangeItem from "./ChangeItem";
import Unreleased from "./Unreleased";

export default function Apple() {
  return (
    <Entries
      href="https://apps.apple.com/us/app/firezone/id6443661826"
      title="macOS / iOS"
    >
      {/* When you cut a release, remove any solved issues from the "known issues" lists over in `client-apps`. This must not be done when the issue's PR merges. */}
      <Unreleased></Unreleased>
      <Entry version="1.3.8" date={new Date("2024-11-05")}>
        <ChangeItem pull="7263">
          Mitigates a crash in case the maximum packet size is not respected.
        </ChangeItem>
        <ChangeItem pull="7265">
          Prevents re-connections to the portal from hanging for longer than 5s.
        </ChangeItem>
        <ChangeItem pull="7288">
            Fixes an issue where network roaming would cause Firezone to become
            unresponsive.
          </ChangeItem>
      </Entry>
      <Entry version="1.3.7" date={new Date("2024-10-31")}>
        <ChangeItem>Handles DNS queries over TCP correctly.</ChangeItem>
        <ChangeItem pull="7152">
          Adds always-on error reporting using sentry.io.
        </ChangeItem>
        <ChangeItem pull="7164">
          Fixes an issue where Firezone would fail to establish connections to
          Gateways and the user had to sign-out and in again.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.6" date={new Date("2024-10-02")}>
        <ChangeItem pull="6831">
          Ensures Firefox doesn't attempt to use DNS over HTTPS when Firezone is
          active.
        </ChangeItem>
        <ChangeItem pull="6845">
          Fixes connectivity issues on idle connections by entering an
          always-on, low-power mode instead of closing them.
        </ChangeItem>
        <ChangeItem pull="6857">
          MacOS: sends hardware's UUID for device verification.
        </ChangeItem>
        <ChangeItem pull="6857">
          iOS: sends Id for vendor for device verification.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.5" date={new Date("2024-09-26")}>
        <ChangeItem pull="6809">
          Fixes a bug where non-wildcard DNS resources were not prioritised over
          wildcard ones (e.g. `app.example.com` vs `*.example.com`).
        </ChangeItem>
      </Entry>
      <Entry version="1.3.4" date={new Date("2024-09-25")}>
        <ChangeItem pull="6788">
          Fixes an issue where some browsers may fail to route DNS Resources
          correctly.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.3" date={new Date("2024-09-19")}>
        <ChangeItem pull="6765">
          Fixes a bug where DNS PTR queries by the system did not get answered.
        </ChangeItem>
        <ChangeItem pull="6722">
          Fixes a routing bug when one of several overlapping CIDR resources
          gets disabled / removed.
        </ChangeItem>
        <ChangeItem>
          Improves logging for DNS queries when{" "}
          <code>firezone_tunnel=trace</code> log level is used.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.2" date={new Date("2024-09-18")}>
        <ChangeItem pull="6632">
          (macOS) Fixes a bug where the addressDescription wasn't fully
          displayed in the macOS menu bar if it exceeded a certain length.
        </ChangeItem>
        <ChangeItem pull="6679">
          (macOS) Displays a notification when a new version is available.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.1" date={new Date("2024-09-05")}>
        <ChangeItem pull="6521">
          Gracefully handles cases where the device's local interface IPv4/IPv6
          address or local network gateway changes while the client is
          connected.
        </ChangeItem>
        <ChangeItem pull="6518">
          Minor improvements to the look of the internet resource and makes the
          Internet resource off by default.
        </ChangeItem>
      </Entry>
      <Entry version="1.3.0" date={new Date("2024-08-30")}>
        <ChangeItem pull="6434">Adds the Internet Resource feature.</ChangeItem>
      </Entry>
      <Entry version="1.2.1" date={new Date("2024-08-22")}>
        <ChangeItem pull="6406">
          Shows the Git SHA corresponding to the build on the Settings -&gt;
          Advanced screen.
        </ChangeItem>
        <ChangeItem pull="6424">
          Fixes a bug where packets would be lost when a connection is first
          established to a Gateway due to routes being updated with no actual
          change.
        </ChangeItem>
      </Entry>
      <Entry version="1.2.0" date={new Date("2024-08-21")}>
        <ChangeItem pull="5901">
          Implements glob-like matching of domains for DNS resources.
        </ChangeItem>
        <ChangeItem pull="6186">
          Adds the ability to mark Resources as favorites.
        </ChangeItem>
        <ChangeItem pull="6361">
          Connections to Gateways are now sticky for the duration of the
          Client's session. This fixes potential issues maintaining long-lived
          TCP connections to Gateways in a high-availability setup.
        </ChangeItem>
      </Entry>
      <Entry version="1.1.5" date={new Date("2024-08-13")}>
        <ChangeItem pull="6276">
          Fixes a bug where relayed connections failed to establish after an
          idle period.
        </ChangeItem>
        <ChangeItem pull="6277">
          Fixes a bug where restrictive NATs caused connectivity problems.
        </ChangeItem>
      </Entry>
      <Entry version="1.1.4" date={new Date("2024-08-10")}>
        <ChangeItem pull="6181">
          Improves reliability of DNS resolution of non-resources.
        </ChangeItem>
      </Entry>
      <Entry version="1.1.3" date={new Date("2024-08-02")}>
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
      </Entry>
      <Entry version="1.1.2" date={new Date("2024-07-03")}>
        <li className="pl-2">
          Prevents Firezone's stub resolver from intercepting DNS record types
          besides A, AAAA, and PTR. These are now forwarded to your upstream DNS
          resolver.
        </li>
      </Entry>
      <Entry version="1.1.1" date={new Date("2024-06-29")}>
        <li className="pl-2">
          Fixes an issue that could cause Resources to be unreachable a few
          hours after roaming networks.
        </li>
        <li className="pl-2">
          Reduces noise in logs for the default log level.
        </li>
      </Entry>
      <Entry version="1.1.0" date={new Date("2024-06-27")}>
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
          more than 5 minutes which reduces power consumption when not accessing
          Resources.
        </li>
        <li className="pl-2">
          Updates log file endings to JSONL and adds syslog-style logs for
          easier readability.
        </li>
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
