import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • Custom reverse proxy",
  description: "Using a custom reverse proxy with Firezone.",
};

export default function Page() {
  return <Content />;
}
