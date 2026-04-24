import { NextResponse } from "next/server";

// RFC 9727 API Catalog — https://www.rfc-editor.org/rfc/rfc9727
export async function GET() {
  const catalog = {
    linkset: [
      {
        anchor: "https://api.firezone.dev",
        "service-desc": [
          {
            href: "https://api.firezone.dev/openapi",
            type: "application/vnd.oai.openapi+json;version=3.0",
          },
        ],
        "service-doc": [
          {
            href: "https://api.firezone.dev/swaggerui",
            type: "text/html",
          },
        ],
      },
    ],
  };

  return new NextResponse(JSON.stringify(catalog), {
    status: 200,
    headers: {
      "Content-Type": "application/linkset+json",
      "Cache-Control": "max-age=3600",
    },
  });
}
