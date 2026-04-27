import { NextResponse } from "next/server";

// RFC 9728 OAuth 2.0 Protected Resource Metadata
// https://www.rfc-editor.org/rfc/rfc9728
// The "resource" field MUST match the origin that hosts this document.
export async function GET() {
  const metadata = {
    resource: "https://www.firezone.dev",
    authorization_servers: ["https://api.firezone.dev"],
    bearer_methods_supported: ["header"],
    resource_documentation: "https://api.firezone.dev/swaggerui",
  };

  return new NextResponse(JSON.stringify(metadata), {
    status: 200,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "max-age=3600",
    },
  });
}
