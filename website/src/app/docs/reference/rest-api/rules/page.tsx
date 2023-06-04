import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • REST API: Rules",
  description: "Firezone REST API: Rules",
};

export default function Page() {
  return <Content />;
}
