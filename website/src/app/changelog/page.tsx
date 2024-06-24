import { Metadata } from "next";
import Changelog from "@/components/Changelog";

export const metadata: Metadata = {
  title: "Changelog • Firezone",
  description: "A list of the most recent updates to Firezone.",
};

export default function Page() {
  const sha = process.env.FIREZONE_DEPLOYED_SHA;

  return <Changelog sha={sha} />;
}
