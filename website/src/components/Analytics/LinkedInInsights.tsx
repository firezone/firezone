"use client";

import { useEffect } from "react";
import { HubSpotSubmittedFormData } from "./types";

export default function LinkedInInsights() {
  const linkedInPartnerId = "6200852";

  useEffect(() => {
    const winAny = window as {
      _linkedin_data_partner_ids?: string[];
      lintrk?: {
        (action: string, data: Record<string, unknown>): void;
        q?: [string, Record<string, unknown>][];
      };
    };
    winAny._linkedin_data_partner_ids = winAny._linkedin_data_partner_ids || [];
    winAny._linkedin_data_partner_ids.push(linkedInPartnerId);

    const initializeLintrk = () => {
      if (winAny.lintrk) return;

      winAny.lintrk = function (a: string, b: Record<string, unknown>) {
        const lintrk = winAny.lintrk;
        if (lintrk) {
          (lintrk.q = lintrk.q || []).push([a, b]);
        }
      };

      const s = document.getElementsByTagName("script")[0];
      const b = document.createElement("script");
      b.type = "text/javascript";
      b.async = true;
      b.src = "https://snap.licdn.com/li.lms-analytics/insight.min.js";
      if (s && s.parentNode) {
        s.parentNode.insertBefore(b, s);
      }
    };

    initializeLintrk();

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

        const win = window as typeof winAny;
        win.lintrk?.("track", { conversion_id: 16519956 });
      }
    };

    window.addEventListener("message", handleMessage);

    return () => {
      window.removeEventListener("message", handleMessage);
    };
  }, [linkedInPartnerId]);

  return null;
}
