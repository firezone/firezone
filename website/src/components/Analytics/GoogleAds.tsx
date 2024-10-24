"use client";

import { useEffect } from "react";
import { HubSpotSubmittedFormData } from "./types";
import { sendGTMEvent } from "@next/third-parties/google";

export default function GoogleAds() {
  const trackingId = process.env.NEXT_PUBLIC_GOOGLE_ANALYTICS_ID;

  useEffect(() => {
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

        const callback = function () {
          return;
        };

        sendGTMEvent({ event: "hubspot-form-submitted" });
      }
    };

    window.addEventListener("message", handleMessage);

    return () => {
      window.removeEventListener("message", handleMessage);
    };
  }, [trackingId]);

  return null;
}
