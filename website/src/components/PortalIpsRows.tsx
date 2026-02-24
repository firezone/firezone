import portalIps from "@/data/portal-ips.json";

type Endpoint = "app.firezone.dev" | "api.firezone.dev";
type Family = "ipv4" | "ipv6";

function renderIps(endpoint: Endpoint, family: Family) {
  const ips = portalIps.endpoints[endpoint][family];
  return ips.map((ip, index) => (
    <span key={`${endpoint}-${family}-${ip}`}>
      {index > 0 ? ", " : ""}
      <code>{ip}</code>
    </span>
  ));
}

export function PortalIpsCell({
  endpoint,
  family,
}: {
  endpoint: Endpoint;
  family: Family;
}) {
  return (
    <>
      {renderIps(endpoint, family)}, see{" "}
      <a href="/portal-ips.json">portal-ips.json</a>
    </>
  );
}
