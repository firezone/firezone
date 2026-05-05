import { Metadata } from "next";
import Changelog from "@/components/Changelog";

export const metadata: Metadata = {
  title: "Product Changelog & Release Notes",
  description:
    "See the latest features, fixes, and improvements shipped to Firezone. Updated with every product release. Subscribe to stay current.",
};

export default function Page() {
  return <Changelog />;
}
