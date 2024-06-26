// app/api/deployed-sha/route.ts
import { NextRequest, NextResponse } from "next/server";

export async function GET(req: NextRequest) {
  const sha = process.env.FIREZONE_DEPLOYED_SHA;
  return NextResponse.json({ sha });
}
