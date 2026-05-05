import _Page from "./_page";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Troubleshooting Guide",
  description:
    "Troubleshoot common Firezone issues. Find solutions for connectivity, DNS, authentication, and Gateway problems — start here for help.",
};

export default function Page() {
  return <_Page />;
}
