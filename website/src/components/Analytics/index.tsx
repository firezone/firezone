import PostHog from "./PostHog";
import GoogleAds from "./GoogleAds";

export default function Analytics() {
  return (
    <>
      <PostHog />
      <GoogleAds />
    </>
  );
}
