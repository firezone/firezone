import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • REST API: Devices",
  description: "Firezone REST API: Devices",
};

export default function Page() {
  return <Content />;
}
