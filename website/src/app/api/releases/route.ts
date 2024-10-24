import { NextRequest, NextResponse } from "next/server";
import { get } from "@vercel/edge-config";

// Cache responses
export const dynamic = "force-static";

// Revalidate cache every 60 seconds
export const revalidate = 60;

export async function GET(_req: NextRequest) {
  const versions = {
    portal: await get("deployed_sha"),
    // mark:current-apple-version
    apple: "1.3.6",
    // mark:current-android-version
    android: "1.3.5",
    // mark:current-gui-version
    gui: "1.3.10",
    // mark:current-headless-version
    headless: "1.3.4",
    // mark:current-gateway-version
    gateway: "1.3.2",
  };

  return NextResponse.json(versions);
}
