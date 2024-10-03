import { NextRequest, NextResponse } from "next/server";
import { get } from "@vercel/edge-config";

export async function GET(_req: NextRequest) {
  const versions = {
    portal: await get("deployed_sha"),
    // mark:current-apple-version
    apple: "1.3.6",
    // mark:current-android-version
    android: "1.3.5",
    // mark:current-gui-version
    gui: "1.3.7",
    // mark:current-headless-version
    headless: "1.3.4",
    // mark:current-gateway-version
    gateway: "1.3.2",
  };

  return NextResponse.json(versions);
}
