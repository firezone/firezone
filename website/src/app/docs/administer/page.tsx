import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • Administer",
  description: "Administering day to day operation of Firezone.",
};

export default function Page() {
  return <Content />;
}
