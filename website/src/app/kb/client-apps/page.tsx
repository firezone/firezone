import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "User Guides • Firezone Docs",
  description:
    "Guides designed to help end-users accomplish common tasks in Firezone.",
};

export default function Page() {
  return <Content />;
}
