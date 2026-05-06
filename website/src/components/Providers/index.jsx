"use client";

// HubspotProvider used to wrap the whole site here, which preloaded
// js.hsforms.net/forms/v2.js on every page even though forms only exist on
// /contact/sales, /product/newsletter, and the blog newsletter footer. The
// provider now lives next to each <NewsletterSignup> / <SalesLeadForm> via
// HubspotForm itself, so the script only loads where there is actually a
// form to render.
export default function Provider({ children }) {
  return <>{children}</>;
}
