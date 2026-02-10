import PostHog from "./PostHog";
import GoogleAds from "./GoogleAds";
import LinkedInInsights from "./LinkedInInsights";

export default function Analytics() {
  return (
    <>
      <PostHog />
      <GoogleAds />
      <LinkedInInsights />
    </>
  );
}
