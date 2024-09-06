import { Metadata } from "next";
import Content from "./readme.mdx";

export const metadata: Metadata = {
  title: "REST API • Firezone Docs",
  description:
    "Learn more about how to automate your Firezone workflows with our REST API.",
};

export default function Page() {
  return <Content />;
}
