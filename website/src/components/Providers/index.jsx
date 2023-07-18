"use client";
import posthog from "posthog-js";
import { PostHogProvider } from "posthog-js/react";
import { HubspotProvider } from "next-hubspot";
import { usePathname, useSearchParams } from "next/navigation";
import { useEffect } from "react";

if (typeof window !== "undefined") {
  posthog.init(process.env.NEXT_PUBLIC_POSTHOG_KEY, {
    api_host: process.env.NEXT_PUBLIC_POSTHOG_HOST,
  });
}

export default function Provider({ children }) {
  const pathname = usePathname();
  const searchParams = useSearchParams();
  // Track pageviews
  useEffect(() => {
    if (pathname) {
      let url = window.origin + pathname;
      if (searchParams.toString()) {
        url = url + `?${searchParams.toString()}`;
      }
      posthog.capture("$pageview", {
        $current_url: url,
      });
    }
  }, [pathname, searchParams]);

  return (
    <>
      <PostHogProvider client={posthog}>
        <HubspotProvider>{children}</HubspotProvider>
      </PostHogProvider>
    </>
  );
}
