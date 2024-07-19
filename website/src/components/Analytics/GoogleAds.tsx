"use client";

import { useEffect } from "react";
import { HubSpotSubmittedFormData } from "./types";

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

        (window as any).gtag("event", "conversion", {
          send_to: `${trackingId}/1wX_CNmzg7MZEPyK3OA9`,
          value: Number(formData.submissionValues["0-2/numberofemployees"]) * 5,
          currency: "USD",
          event_callback: callback,
        });
      }
    };

    window.addEventListener("message", handleMessage);

    return () => {
      window.removeEventListener("message", handleMessage);
    };
  }, [trackingId]);

  return null;
}
