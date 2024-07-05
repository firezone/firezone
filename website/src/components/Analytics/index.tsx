import Mixpanel from "./Mixpanel";
import GoogleAds from "./GoogleAds";
import LinkedInInsights from "./LinkedInInsights";
import { GoogleAnalytics } from "@next/third-parties/google";

export default function Analytics() {
  const gaId = process.env.NEXT_PUBLIC_GOOGLE_ANALYTICS_ID;

  return (
    <>
      <Mixpanel />
      <GoogleAds />
      {gaId && gaId.length > 0 && <GoogleAnalytics gaId={gaId} />}
      <LinkedInInsights />
    </>
  );
}
