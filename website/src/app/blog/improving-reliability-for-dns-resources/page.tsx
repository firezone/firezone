import _Page from "./_page";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Improving reliability for DNS Resources • Firezone Blog",
  description:
    "Client and Gateway versions 1.1 onwards include a more reliable DNS routing system.",
};

export default function Page() {
  return <_Page />;
}
