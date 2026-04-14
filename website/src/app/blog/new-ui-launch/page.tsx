import _Page from "./_page";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "A New Look for Firezone • Firezone Blog",
  description: "Announcing the new user interface for the Firezone portal.",
};

export default function Page() {
  return <_Page />;
}
