import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • REST API: Users",
  description: "Firezone REST API: Users",
};

export default function Page() {
  return <Content />;
}
