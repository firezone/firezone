#!/usr/bin/env node
import { promises as dns } from "node:dns";
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const REGION_HOSTS = [
  "australiaeast-portal.firezone.dev",
  "northeurope-portal.firezone.dev",
  "centralus-portal.firezone.dev",
];

const PUBLIC_JSON_PATH = resolve("public/portal-ips.json");
const SRC_JSON_PATH = resolve("src/data/portal-ips.json");

const mode = process.argv[2] ?? "check";
if (!["check", "update"].includes(mode)) {
  console.error("Usage: node scripts/portal-ips.mjs [check|update]");
  process.exit(2);
}

function sortUnique(values) {
  return [...new Set(values)].sort();
}

async function resolveFamily(host, family) {
  try {
    const records =
      family === 4 ? await dns.resolve4(host) : await dns.resolve6(host);
    return sortUnique(records);
  } catch (error) {
    if (
      error &&
      (error.code === "ENODATA" ||
        error.code === "ENOTFOUND" ||
        error.code === "SERVFAIL")
    ) {
      return [];
    }

    throw error;
  }
}

async function resolveHost(host) {
  const [ipv4, ipv6] = await Promise.all([
    resolveFamily(host, 4),
    resolveFamily(host, 6),
  ]);

  return { ipv4, ipv6 };
}

async function computePortalIps() {
  const regionalHosts = {};
  for (const host of REGION_HOSTS) {
    regionalHosts[host] = await resolveHost(host);
  }

  const allIpv4 = sortUnique(
    REGION_HOSTS.flatMap((host) => regionalHosts[host].ipv4)
  );
  const allIpv6 = sortUnique(
    REGION_HOSTS.flatMap((host) => regionalHosts[host].ipv6)
  );

  return {
    generated_at: new Date().toISOString(),
    regions: ["centralus", "australiaeast", "northeurope"],
    regional_hosts: regionalHosts,
    endpoints: {
      "app.firezone.dev": {
        ipv4: allIpv4,
        ipv6: allIpv6,
      },
      "api.firezone.dev": {
        ipv4: allIpv4,
        ipv6: allIpv6,
      },
    },
  };
}

function normalizeForCompare(payload) {
  const rest = { ...payload };
  delete rest.generated_at;
  return rest;
}

function readSnapshot() {
  const raw = readFileSync(SRC_JSON_PATH, "utf8");
  return JSON.parse(raw);
}

function writeSnapshot(payload) {
  const json = `${JSON.stringify(payload, null, 2)}\n`;
  writeFileSync(PUBLIC_JSON_PATH, json);
}

function printDiff(current, snapshot) {
  console.error("DNS resolution does not match src/data/portal-ips.json");
  console.error(
    "Run `pnpm update:portal-ips` to refresh public/portal-ips.json."
  );

  const endpoints = ["app.firezone.dev", "api.firezone.dev"];
  const families = ["ipv4", "ipv6"];

  for (const endpoint of endpoints) {
    for (const family of families) {
      const expected = (snapshot.endpoints?.[endpoint]?.[family] ?? []).join(
        ", "
      );
      const actual = (current.endpoints?.[endpoint]?.[family] ?? []).join(", ");

      if (expected !== actual) {
        console.error(`- ${endpoint} ${family}`);
        console.error(`  snapshot: ${expected || "<empty>"}`);
        console.error(`  resolved: ${actual || "<empty>"}`);
      }
    }
  }
}

const resolved = await computePortalIps();

if (mode === "update") {
  writeSnapshot(resolved);
  console.log("Updated public/portal-ips.json");
  process.exit(0);
}

let snapshot;
try {
  snapshot = readSnapshot();
} catch {
  console.error("Missing src/data/portal-ips.json");
  console.error("Run `pnpm update:portal-ips` to generate it.");
  process.exit(1);
}

if (
  JSON.stringify(normalizeForCompare(resolved)) !==
  JSON.stringify(normalizeForCompare(snapshot))
) {
  printDiff(resolved, snapshot);
  process.exit(1);
}

console.log("portal-ips.json matches live DNS resolution");
