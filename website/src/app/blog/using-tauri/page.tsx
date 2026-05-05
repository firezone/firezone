import _Page from "./_page";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Building Cross-Platform Apps with Tauri",
  description:
    "Read why Firezone chose Tauri to build native Linux and Windows clients. A look at our cross-platform desktop app architecture and tradeoffs.",
};

export default function Page() {
  return <_Page />;
}
