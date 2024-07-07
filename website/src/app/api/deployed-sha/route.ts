// app/api/deployed-sha/route.ts
import { NextRequest, NextResponse } from "next/server";
import { get } from "@vercel/edge-config";

export async function GET(_req: NextRequest) {
  const sha = await get("deployed_sha");
  return NextResponse.json({ sha });
}
