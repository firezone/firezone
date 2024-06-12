import _Page from "./_page";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Using Tauri to build a cross-platform security app",
  description: "A post about how Firezone uses Tauri on Linux and Windows",
};

export default function Page() {
  return <_Page />;
}
