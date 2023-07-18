import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "REST API: Configurations • Firezone Docs",
  description: "REST API documentation for configuring Firezone.",
};

export default function Page() {
  return <Content />;
}
