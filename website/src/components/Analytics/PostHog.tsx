"use client";

import { useEffect, Suspense } from "react";
import { usePathname, useSearchParams } from "next/navigation";
import posthog from "posthog-js";
import { HubSpotSubmittedFormData } from "./types";

function PostHogComponent() {
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const apiKey = "phc_ubuPhiqqjMdedpmbWpG2Ak3axqv5eMVhFDNBaXl9UZK";

  useEffect(() => {
    if (!pathname) return;

    posthog.init(apiKey, { api_host: "https://us.i.posthog.com" });

    let url = window.origin + pathname;
    if (searchParams.toString()) {
      url = url + `?${searchParams.toString()}`;
    }
    posthog.capture("$pageview", {
      $current_url: url,
    });

    const handleMessage = (event: MessageEvent) => {
      if (
        event.data.type === "hsFormCallback" &&
        event.data.eventName === "onFormSubmitted"
      ) {
        const formData: HubSpotSubmittedFormData = event.data.data;
        if (!formData || !formData.formGuid || !formData.submissionValues) {
          console.error("Missing form data:", formData);
          return;
        }

        if (
          formData.submissionValues.email &&
          formData.submissionValues.firstname &&
          formData.submissionValues.lastname
        ) {
          posthog.identify(formData.submissionValues.email);
          posthog.people.set({
            email: formData.submissionValues.email,
            first_name: formData.submissionValues.firstname,
            last_name: formData.submissionValues.lastname,
          });

          posthog.capture("HubSpot Form Submitted", {
            formId: formData.formGuid,
            conversionId: formData.conversionId,
          });
        }
      }
    };

    window.addEventListener("message", handleMessage);

    return () => {
      window.removeEventListener("message", handleMessage);
    };
  }, [pathname, searchParams, apiKey]);

  return null;
}

export default function PostHog() {
  return (
    <Suspense fallback={null}>
      <PostHogComponent />
    </Suspense>
  );
}
