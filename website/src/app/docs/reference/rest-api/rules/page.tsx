import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "REST API: Rules • Firezone Docs",
  description: "REST API documentation for rules in Firezone.",
};

export default function Page() {
  return <Content />;
}
