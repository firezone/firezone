"use client";

import { useEffect } from "react";
import posthog from "posthog-js";
import { HubSpotSubmittedFormData } from "./types";

const apiKey = "phc_ubuPhiqqjMdedpmbWpG2Ak3axqv5eMVhFDNBaXl9UZK";

export default function PostHog() {
  useEffect(() => {
    if (!(posthog as unknown as { __loaded?: boolean }).__loaded) {
      posthog.init(apiKey, {
        api_host: "https://e.firezone.dev",
        defaults: "2026-01-30",
      });
    }

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
  }, []);

  return null;
}
