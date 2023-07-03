import HubspotForm from "@/components/HubspotForm";

export default function NewsletterSignup() {
  return (
    <section>
      <div className="py-8 px-4 mx-auto max-w-screen-xl lg:py-16 lg:px-6">
        <div className="mx-auto max-w-screen-md sm:text-center">
          <h2 className="justify-center mb-4 text-2xl font-extrabold tracking-tight text-neutral-900 sm:text-6xl dark:text-white">
            Firezone Product Newsletter
          </h2>
          <p className="mx-auto mb-8 max-w-2xl text-neutral-800 md:mb-12 sm:text-xl dark:text-neutral-100">
            Sign up with your email to receive roadmap updates, how-tos, and
            product announcements from the Firezone team.
          </p>
        </div>
        <div className="mx-auto max-w-screen-sm">
          <HubspotForm
            region="na1"
            portalId="23723443"
            formId="a45bf30a-3aca-4523-9bc8-7dc2dc3f6176"
          />
        </div>
      </div>
    </section>
  );
}
