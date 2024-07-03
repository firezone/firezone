"use client";

import { useEffect, Suspense } from "react";
import { usePathname, useSearchParams } from "next/navigation";
import { useMixpanel } from "react-mixpanel-browser";
import { HubSpotSubmittedFormData } from "./types";

export default function Mixpanel() {
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
