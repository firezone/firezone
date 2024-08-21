// import Mixpanel from "./Mixpanel";
import GoogleAds from "./GoogleAds";
import LinkedInInsights from "./LinkedInInsights";

export default function Analytics() {
  return (
    <>
      {/* <Mixpanel /> */}
      <GoogleAds />
      <LinkedInInsights />
    </>
  );
}
