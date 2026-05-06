export const SITE_URL = "https://www.firezone.dev";

export const organizationSchema = {
  "@context": "https://schema.org",
  "@type": "Organization",
  "@id": `${SITE_URL}/#organization`,
  name: "Firezone",
  url: SITE_URL,
  logo: {
    "@type": "ImageObject",
    url: `${SITE_URL}/images/logo-main-light-primary.svg`,
  },
  sameAs: [
    "https://github.com/firezone/firezone",
    "https://x.com/firezonehq",
    "https://www.linkedin.com/company/firezonehq",
    "https://www.youtube.com/@firezonehq",
  ],
};

// SearchAction was previously declared here pointing at /kb?q=... but the
// site does not actually parse a `q` query parameter or render search
// results from it, so advertising the endpoint to crawlers would be
// misleading. Re-add SearchAction once an on-site search endpoint exists.
export const websiteSchema = {
  "@context": "https://schema.org",
  "@type": "WebSite",
  "@id": `${SITE_URL}/#website`,
  url: SITE_URL,
  name: "Firezone",
  publisher: { "@id": `${SITE_URL}/#organization` },
};

export function articleSchema(args: {
  title: string;
  description?: string;
  authorName: string;
  date: string;
  url: string;
  image?: string;
}) {
  const isoDate = toIsoDate(args.date);
  return {
    "@context": "https://schema.org",
    // BlogPosting is a strict subtype of Article. Google ranks both the same
    // but BlogPosting is the more specific (and so preferred) hint for the
    // /blog/* tree.
    "@type": "BlogPosting",
    headline: args.title,
    description: args.description,
    datePublished: isoDate,
    dateModified: isoDate,
    author: { "@type": "Person", name: args.authorName },
    publisher: { "@id": `${SITE_URL}/#organization` },
    mainEntityOfPage: { "@type": "WebPage", "@id": args.url },
    image: args.image ?? `${SITE_URL}/images/logo-main-light-primary.svg`,
  };
}

export function breadcrumbSchema(items: { name: string; url: string }[]) {
  return {
    "@context": "https://schema.org",
    "@type": "BreadcrumbList",
    itemListElement: items.map((item, index) => ({
      "@type": "ListItem",
      position: index + 1,
      name: item.name,
      item: item.url,
    })),
  };
}

export function faqPageSchema(items: { question: string; answer: string }[]) {
  return {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    mainEntity: items.map((item) => ({
      "@type": "Question",
      name: item.question,
      acceptedAnswer: { "@type": "Answer", text: item.answer },
    })),
  };
}

export type ReviewInput = {
  authorName: string;
  reviewBody: string;
  /** Organization the reviewer belongs to (e.g. their employer). */
  affiliation?: string;
  /** Optional URL the review's author endorsement points at. */
  url?: string;
  /** Optional 1–5 rating. Omit when reviews are testimonial-only. */
  ratingValue?: number;
};

export function reviewSchema(args: ReviewInput) {
  const author: Record<string, unknown> = {
    "@type": "Person",
    name: args.authorName,
  };
  if (args.affiliation) {
    author.affiliation = { "@type": "Organization", name: args.affiliation };
  }

  const review: Record<string, unknown> = {
    "@context": "https://schema.org",
    "@type": "Review",
    author,
    reviewBody: args.reviewBody,
    publisher: { "@id": `${SITE_URL}/#organization` },
  };
  if (args.url) review.url = args.url;
  if (typeof args.ratingValue === "number") {
    review.reviewRating = {
      "@type": "Rating",
      ratingValue: args.ratingValue,
      bestRating: 5,
      worstRating: 1,
    };
  }
  return review;
}

export function aggregateRatingSchema(args: {
  ratingValue: number;
  reviewCount: number;
}) {
  return {
    "@context": "https://schema.org",
    "@type": "AggregateRating",
    ratingValue: args.ratingValue,
    reviewCount: args.reviewCount,
    bestRating: 5,
    worstRating: 1,
  };
}

// Two flavors of Offer:
//   - Priced: an actual public price (Starter, Team, etc.).
//   - Contact-sales: no public price — these only set `availability` to
//     `InStock` and an `url` pointing at the sales contact form. We do NOT
//     emit `price`/`priceCurrency` because a placeholder ($0, "TBD", etc.)
//     causes search engines to surface incorrect rich-result pricing.
export type OfferInput = {
  name?: string;
  /** schema.org/Offer.url — link straight at the pricing card / signup. */
  url?: string;
} & (
  | { price: string; priceCurrency: string }
  | { price?: undefined; priceCurrency?: undefined }
);

export function softwareApplicationSchema(args: {
  name: string;
  description: string;
  url: string;
  category: string;
  offers?: OfferInput[];
  reviews?: ReviewInput[];
  aggregateRating?: { ratingValue: number; reviewCount: number };
}) {
  const schema: Record<string, unknown> = {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: args.name,
    description: args.description,
    url: args.url,
    applicationCategory: args.category,
    operatingSystem: "macOS, Windows, Linux, iOS, Android, ChromeOS",
    publisher: { "@id": `${SITE_URL}/#organization` },
  };
  if (args.offers) {
    schema.offers = args.offers.map(buildOffer);
  }
  if (args.reviews && args.reviews.length > 0) {
    schema.review = args.reviews.map((r) => withoutContext(reviewSchema(r)));
  }
  if (args.aggregateRating) {
    schema.aggregateRating = withoutContext(
      aggregateRatingSchema(args.aggregateRating)
    );
  }
  return schema;
}

/**
 * Generic Product schema. Prefer `softwareApplicationSchema` for Firezone
 * itself (more specific subtype). Use `productSchema` for non-software product
 * cards or comparison pages where Product is the right shape.
 */
export function productSchema(args: {
  name: string;
  description: string;
  url: string;
  brand?: string;
  offers?: OfferInput[];
  reviews?: ReviewInput[];
  aggregateRating?: { ratingValue: number; reviewCount: number };
}) {
  const schema: Record<string, unknown> = {
    "@context": "https://schema.org",
    "@type": "Product",
    name: args.name,
    description: args.description,
    url: args.url,
  };
  if (args.brand) schema.brand = { "@type": "Brand", name: args.brand };
  if (args.offers) {
    schema.offers = args.offers.map(buildOffer);
  }
  if (args.reviews && args.reviews.length > 0) {
    schema.review = args.reviews.map((r) => withoutContext(reviewSchema(r)));
  }
  if (args.aggregateRating) {
    schema.aggregateRating = withoutContext(
      aggregateRatingSchema(args.aggregateRating)
    );
  }
  return schema;
}

// Strip the outer @context when embedding a sub-entity inside a parent
// schema; the parent's @context already covers the embedded entity.
function withoutContext(node: Record<string, unknown>) {
  const copy = { ...node };
  delete copy["@context"];
  return copy;
}

function buildOffer(offer: OfferInput) {
  const out: Record<string, unknown> = { "@type": "Offer" };
  if (offer.price !== undefined) {
    out.price = offer.price;
    out.priceCurrency = offer.priceCurrency;
  } else {
    // Contact-sales / negotiated price. We omit price/priceCurrency
    // entirely; advertising the offer with a $0 placeholder would let
    // search engines display an incorrect free-tier price for this plan.
    out.availability = "https://schema.org/InStock";
  }
  if (offer.name) out.name = offer.name;
  if (offer.url) out.url = offer.url;
  return out;
}

function toIsoDate(input: string): string {
  const date = new Date(input);
  if (Number.isNaN(date.getTime())) return input;
  return date.toISOString().slice(0, 10);
}
