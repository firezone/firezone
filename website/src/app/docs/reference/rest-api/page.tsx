import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "REST API • Firezone Docs",
  description: "REST API documentation for Firezone.",
};

export default function Page() {
  return <Content />;
}
