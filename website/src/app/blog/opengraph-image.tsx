import { ImageResponse } from "next/og";
import { FIREZONE_LOGO_DATA_URL } from "@/lib/og-assets";

export const alt = "Firezone Blog — engineering, networking, and zero trust";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export default function Image() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "space-between",
          padding: "80px",
          background:
            "linear-gradient(135deg, #0F1419 0%, #1A2433 60%, #1F8FFF 110%)",
          color: "#FFFFFF",
          fontFamily: "system-ui, -apple-system, sans-serif",
        }}
      >
        <div
          style={{
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
          }}
        >
          <img
            src={FIREZONE_LOGO_DATA_URL}
            alt="Firezone"
            width={228}
            height={72}
            style={{ display: "flex" }}
          />
          <div
            style={{
              padding: "10px 22px",
              borderRadius: 999,
              background: "rgba(31, 143, 255, 0.18)",
              border: "1px solid rgba(31, 143, 255, 0.5)",
              color: "#B6D6FF",
              fontSize: 22,
              fontWeight: 600,
              letterSpacing: "0.04em",
              textTransform: "uppercase",
            }}
          >
            Blog
          </div>
        </div>

        <div style={{ display: "flex", flexDirection: "column" }}>
          <div
            style={{
              fontSize: 88,
              fontWeight: 800,
              lineHeight: 1.05,
              letterSpacing: "-0.03em",
            }}
          >
            Zero Trust Insights
          </div>
          <div
            style={{
              marginTop: 24,
              fontSize: 30,
              color: "#B6C2CF",
              maxWidth: 920,
              lineHeight: 1.3,
            }}
          >
            Announcements, deep dives, and security insights from the Firezone
            team.
          </div>
        </div>

        <div
          style={{
            display: "flex",
            justifyContent: "space-between",
            alignItems: "center",
            color: "#8FA3B5",
            fontSize: 24,
          }}
        >
          <div>firezone.dev/blog</div>
          <div>WireGuard® · Rust · Networking</div>
        </div>
      </div>
    ),
    { ...size }
  );
}
