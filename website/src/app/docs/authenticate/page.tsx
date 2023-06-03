import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • Authenticate",
  description: "Authenticating with Firezone.",
};

export default function Page() {
  return <Content />;
}
