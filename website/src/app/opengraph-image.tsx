import { ImageResponse } from "next/og";
import { FIREZONE_LOGO_DATA_URL } from "@/lib/og-assets";

export const alt = "Firezone — Zero Trust Access for the Enterprise";
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
            "linear-gradient(135deg, #0F1419 0%, #1A2433 60%, #0B5394 100%)",
          color: "#FFFFFF",
          fontFamily: "system-ui, -apple-system, sans-serif",
        }}
      >
        <img
          src={FIREZONE_LOGO_DATA_URL}
          alt="Firezone"
          width={266}
          height={84}
          style={{ display: "flex" }}
        />

        <div style={{ display: "flex", flexDirection: "column" }}>
          <div
            style={{
              fontSize: 80,
              fontWeight: 800,
              lineHeight: 1.05,
              letterSpacing: "-0.03em",
              maxWidth: 960,
            }}
          >
            Zero Trust Access for the Enterprise
          </div>
          <div
            style={{
              marginTop: 28,
              fontSize: 32,
              color: "#B6C2CF",
              maxWidth: 900,
              lineHeight: 1.3,
            }}
          >
            Open-source zero trust access built on WireGuard®.
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
          <div>firezone.dev</div>
          <div>Built on WireGuard®</div>
        </div>
      </div>
    ),
    { ...size }
  );
}
