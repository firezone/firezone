import { Metadata } from "next";
import _Page from "./_page";

export const metadata: Metadata = {
  title: "Scheduled Maintenance - December 6, 2025 • Firezone Blog",
  description:
    "Firezone will undergo scheduled maintenance on December 6, 2025 from 8pm to 10pm Pacific Time to roll out major improvements to authentication, directory sync, and user management.",
};

export default function Page() {
  return <_Page />;
}
