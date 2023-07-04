"use client";
import { useHubspotForm } from "next-hubspot";

export default function HubspotForm({
  portalId,
  formId,
}: {
  portalId: string;
  formId: string;
}) {
  const { loaded, error, formCreated } = useHubspotForm({
    portalId: portalId,
    formId: formId,
    target: "#hubspot-form",
  });

  return (
    <div className="bg-white shadow-md border border-neutral-200 dark:border-neutral-700 rounded-lg p-4">
      <div id="hubspot-form" />
    </div>
  );
}
