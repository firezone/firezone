"use client";

import { useEffect } from "react";
import { HubSpotSubmittedFormData } from "./types";
import { sendGTMEvent } from "@next/third-parties/google";

export default function GoogleAds() {
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

        const value =
          Number(formData.submissionValues["0-2/numberofemployees"]) * 5;

        sendGTMEvent({
          event: "gtm.js",
        });

        sendGTMEvent({
          event: "gtm.formSubmit",
          conversionValue: value,
        });
      }
    };

    window.addEventListener("message", handleMessage);

    return () => {
      window.removeEventListener("message", handleMessage);
    };
  }, []);

  return null;
}
