import { NextResponse } from "next/server";

// RFC 9728 OAuth 2.0 Protected Resource Metadata
// https://www.rfc-editor.org/rfc/rfc9728
export async function GET() {
  const metadata = {
    resource: "https://api.firezone.dev",
    bearer_methods_supported: ["header"],
    resource_documentation: "https://api.firezone.dev/swaggerui",
    resource_signing_alg_values_supported: [],
    scopes_supported: [],
  };

  return new NextResponse(JSON.stringify(metadata), {
    status: 200,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "max-age=3600",
    },
  });
}
