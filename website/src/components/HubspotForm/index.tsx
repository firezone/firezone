"use client";
import { useEffect } from "react";
import { useHubspotForm } from "next-hubspot";

export default function HubspotForm({
  portalId,
  formId,
  title,
}: {
  portalId: string;
  formId: string;
  title?: string;
}) {
  useHubspotForm({
    portalId: portalId,
    formId: formId,
    target: "#hubspot-form",
  });

  // HubSpot collapses the iframe to ~20px after submission, hiding the
  // thank-you message. Listen for the submit callback and force a min-height.
  useEffect(() => {
    const handleMessage = (event: MessageEvent) => {
      if (
        event.data.type === "hsFormCallback" &&
        event.data.eventName === "onFormSubmitted"
      ) {
        const iframe = document.querySelector(
          "#hubspot-form iframe"
        ) as HTMLIFrameElement | null;
        if (iframe) {
          iframe.style.minHeight = "100px";
        }
      }
    };

    window.addEventListener("message", handleMessage);
    return () => window.removeEventListener("message", handleMessage);
  }, []);

  return (
    <div className="bg-white shadow-md border border-neutral-200  rounded-sm p-4">
      <h3 className="mb-4 lg:mb-8 text-xl font-bold tracking-tight text-neutral-900 sm:text-xl border-b ">
        {title}
      </h3>
      <div id="hubspot-form" className="min-h-[300px]" />
    </div>
  );
}
