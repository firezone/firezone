import Content from "./readme.mdx";
import { Metadata } from "next";
import LastUpdated from "@/components/LastUpdated";

export const metadata: Metadata = {
  title: "Windows Client • Firezone Docs",
  description: "How to install and use the Firezone Windows GUI client.",
};

export default function Page() {
  return (
    <>
      <Content />
      <LastUpdated dirname={__dirname} />
    </>
  );
}
