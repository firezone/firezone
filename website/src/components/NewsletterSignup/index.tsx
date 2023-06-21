import HubspotForm from "@/components/HubspotForm";

export default function NewsletterSignup() {
  return (
    <section className="bg-white dark:bg-gray-900">
      <div className="py-8 px-4 mx-auto max-w-screen-xl lg:py-16 lg:px-6">
        <div className="mx-auto max-w-screen-md sm:text-center">
          <h2 className="justify-center mb-4 text-3xl font-extrabold tracking-tight text-gray-900 sm:text-4xl dark:text-white">
            Firezone Product Newsletter
          </h2>
          <p className="mx-auto mb-8 max-w-2xl font-light text-gray-500 md:mb-12 sm:text-xl dark:text-gray-400">
            Sign up with your email to receive roadmap updates, how-tos, and product announcements from the Firezone team.
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
  )
}
