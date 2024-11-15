import { NextRequest, NextResponse } from "next/server";
import { get } from "@vercel/edge-config";

// Cache responses
export const dynamic = "force-static";

// Revalidate cache at most every hour
export const revalidate = 3600;

export async function GET(_req: NextRequest) {
  const versions = {
    portal: await get("deployed_sha"),
    // mark:current-apple-version
    apple: "1.3.9",
    // mark:current-android-version
    android: "1.3.7",
    // mark:current-gui-version
    gui: "1.3.12",
    // mark:current-headless-version
    headless: "1.3.7",
    // mark:current-gateway-version
    gateway: "1.4.1",
  };

  return NextResponse.json(versions);
}
