import { Metadata } from "next";
import _Page from "./_page";

export const metadata: Metadata = {
  title: "Maintenance Window — Dec 6, 2025",
  description:
    "Firezone scheduled maintenance on December 6, 2025 from 8–10 PM PT to deploy authentication, directory sync, and user management updates.",
};

export default function Page() {
  return <_Page />;
}
