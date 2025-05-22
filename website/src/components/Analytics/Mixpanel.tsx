"use client";

import { useEffect, Suspense } from "react";
import { usePathname, useSearchParams } from "next/navigation";
import mixpanel from "mixpanel-browser";
import { HubSpotSubmittedFormData } from "./types";

function _Mixpanel() {
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const mpToken = process.env.NEXT_PUBLIC_MIXPANEL_TOKEN || "dummy";
  const host = "https://t.firez.one";

  useEffect(() => {
    if (!pathname) return;
    if (!mixpanel) return;

    mixpanel.init(mpToken, { api_host: host });

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

  return null;
}

export default function Mixpanel() {
  return (
    <Suspense fallback={null}>
      <_Mixpanel />
    </Suspense>
  );
}
