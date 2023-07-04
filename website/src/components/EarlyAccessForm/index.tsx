import HubspotForm from "@/components/HubspotForm";

export default function EarlyAccessForm() {
  return (
    <div className="py-8 px-4 mx-auto max-w-screen-xl lg:py-16 lg:px-6">
      <div className="mx-auto max-w-screen-md sm:text-center">
        <h2 className="justify-center mb-4 text-2xl font-extrabold tracking-tight text-neutral-900 sm:text-6xl dark:text-white">
          Request early access
        </h2>
        <p className="mx-auto mb-8 max-w-2xl text-neutral-800 md:mb-12 sm:text-xl dark:text-neutral-100">
          Firezone 1.0 is coming! Fill out the form below to be get early
          access.
        </p>
      </div>
      <div className="mx-auto max-w-screen-sm">
        <HubspotForm
          portalId="23723443"
          formId="1a618e17-ef54-4325-bf0e-ed2431cc8cd2"
        />
      </div>
    </div>
  );
}
