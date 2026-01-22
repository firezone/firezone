"use client";
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

  return (
    <div className="bg-white shadow-md border border-neutral-200  rounded-sm p-4">
      <h3 className="mb-4 lg:mb-8 text-xl font-bold tracking-tight text-neutral-900 sm:text-xl border-b ">
        {title}
      </h3>
      <div id="hubspot-form" />
    </div>
  );
}
