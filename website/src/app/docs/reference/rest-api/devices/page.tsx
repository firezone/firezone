import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "REST API: Devices • Firezone Docs",
  description: "REST API documentation for devices in Firezone.",
};

export default function Page() {
  return <Content />;
}
