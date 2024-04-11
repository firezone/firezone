import { Metadata } from "next";
import _Page from "./_page";
import LastUpdated from "@/components/LastUpdated";

export const metadata: Metadata = {
  title: "Deploy • Firezone Docs",
  description: "Firezone Documentation",
};

export default function Page() {
  return (
    <>
      <_Page />
      <LastUpdated dirname={__dirname} />
    </>
  );
}
