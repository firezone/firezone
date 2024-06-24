import _Page from "./_page";
import { Metadata } from "next";
import LastUpdated from "@/components/LastUpdated";

export const metadata: Metadata = {
  title: "Auth0 • Firezone Docs",
  description: "OIDC Authentication with Auth0",
};

export default function Page() {
    return (
      <>
        <_Page />
        <LastUpdated dirname={__dirname} />
      </>
    );
  }
