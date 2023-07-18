import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Telemetry • Firezone Docs",
  description: "Information on what telemetry Firezone collects.",
};

export default function Page() {
  return <Content />;
}
