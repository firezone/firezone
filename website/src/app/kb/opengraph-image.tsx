import { ImageResponse } from "next/og";
import { FIREZONE_LOGO_DATA_URL } from "@/lib/og-assets";

export const alt =
  "Firezone Documentation — setup, deploy, and operate Firezone";
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
            "linear-gradient(135deg, #0F1419 0%, #1A2433 55%, #134B7A 100%)",
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
              background: "rgba(255, 255, 255, 0.08)",
              border: "1px solid rgba(255, 255, 255, 0.25)",
              color: "#E0E8F0",
              fontSize: 22,
              fontWeight: 600,
              letterSpacing: "0.04em",
              textTransform: "uppercase",
            }}
          >
            Docs
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
            Firezone Documentation
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
            Setup, deploy, configure, and scale Firezone — guides for clients,
            gateways, and identity providers.
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
          <div>firezone.dev/kb</div>
          <div>Quickstart · Deploy · Authenticate</div>
        </div>
      </div>
    ),
    { ...size }
  );
}
