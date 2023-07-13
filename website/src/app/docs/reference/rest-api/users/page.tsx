import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "REST API: Users • Firezone Docs",
  description: "REST API documentation for users in Firezone.",
};

export default function Page() {
  return <Content />;
}
