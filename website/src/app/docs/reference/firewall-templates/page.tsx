import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • REST API: Configurations",
  description: "REST API: Configurations",
};

export default function Page() {
  return <Content />;
}
