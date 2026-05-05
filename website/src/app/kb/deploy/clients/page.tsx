import _Page from "./_page";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Clients",
  description:
    "Distribute Firezone Clients to your team across macOS, Windows, Linux, iOS, Android, and ChromeOS. See the client distribution guide.",
};

export default function Page() {
  return <_Page />;
}
