"use client";
import { useEffect, Suspense } from "react";
import { usePathname, useSearchParams } from "next/navigation";
import { useMixpanel } from "react-mixpanel-browser";
import { HubSpotSubmittedFormData } from "./types";

export function Mixpanel() {
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const mixpanel = useMixpanel();

  useEffect(() => {
    if (!pathname) return;
    if (!mixpanel) return;

    let url = window.origin + pathname;
    if (searchParams.toString()) {
      url = url + `?${searchParams.toString()}`;
    }
    mixpanel.track("$mp_web_page_view", {
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
          mixpanel.people.set({
            $email: formData.submissionValues.email,
            $first_name: formData.submissionValues.firstname,
            $last_name: formData.submissionValues.lastname,
          });

          mixpanel.track("HubSpot Form Submitted", {
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
  }, [pathname, searchParams, mixpanel]);

  return <Suspense />;
}

export function GoogleAds() {
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

export function LinkedInInsights() {
  const linkedInPartnerId = process.env.NEXT_PUBLIC_LINKEDIN_PARTNER_ID;

  useEffect(() => {
    const winAny = window as any;
    winAny._linkedin_data_partner_ids = winAny._linkedin_data_partner_ids || [];
    winAny._linkedin_data_partner_ids.push(linkedInPartnerId);

    const initializeLintrk = () => {
      if (winAny.lintrk) return;

      winAny.lintrk = function (a: any, b: any) {
        (winAny.lintrk.q = winAny.lintrk.q || []).push([a, b]);
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

        (window as any).lintrk("track", { conversion_id: 16519956 });
      }
    };

    window.addEventListener("message", handleMessage);

    return () => {
      window.removeEventListener("message", handleMessage);
    };
  }, [linkedInPartnerId]);

  return null;
}
