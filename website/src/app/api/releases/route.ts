import { NextRequest, NextResponse } from "next/server";
import { get } from "@vercel/edge-config";

export async function GET(_req: NextRequest) {
  const versions = {
    portal: await get("deployed_sha"),
    // mark:current-apple-version
    apple: "1.4.7",
    // mark:current-android-version
    android: "1.4.4",
    // mark:current-gui-version
    gui: "1.4.9",
    // mark:current-headless-version
    headless: "1.4.5",
    // mark:current-gateway-version
    gateway: "1.4.5",
  };

  return NextResponse.json(versions, {
    status: 200,
    // Vercel's Edge Cache to have a TTL of 3600 seconds
    // Downstream CDNs to have a TTL of 60 seconds
    // Clients to have a TTL of 10 seconds
    headers: {
      "Cache-Control": "max-age=10",
      "CDN-Cache-Control": "max-age=60",
      "Vercel-CDN-Cache-Control": "max-age=3600",
    },
  });
}
