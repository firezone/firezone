import HubspotForm from "@/components/HubspotForm";

export default function NewsletterSignup() {
  return (
    <div className="mx-auto max-w-screen-sm">
      <HubspotForm
        title="Sign up for our newsletter"
        portalId="23723443"
        formId="a45bf30a-3aca-4523-9bc8-7dc2dc3f6176"
      />
    </div>
  );
}
