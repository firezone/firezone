import { NextRequest, NextResponse } from "next/server";
import { get } from "@vercel/edge-config";

export async function GET(_req: NextRequest) {
  const versions = {
    portal: await get("deployed_sha"),
    // mark:current-apple-version
    apple: "1.3.1",
    // mark:current-android-version
    android: "1.3.2",
    // mark:current-gui-version
    gui: "1.3.2",
    // mark:current-headless-version
    headless: "1.3.1",
    // mark:current-gateway-version
    gateway: "1.3.1",
  };

  return NextResponse.json(versions);
}
