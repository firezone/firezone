import HubspotForm from "@/components/HubspotForm";

export default function Page() {
  return (
    <div>
      <div>
        <div>
          <h1>Talk to a Firezone expert</h1>
          <p>
            Ready to manage secure remote access for your organization? Learn
            how Firezone can help.
          </p>
        </div>
      </div>

      <center>
        <h2>Contact sales</h2>
      </center>

      <div>
        <div>
          <div>
            <h3>Ensure business continuity</h3>
            <ul>
              <li>Technical support with SLAs</li>
              <li>Private Slack channel</li>
              <li>White-glove onboarding</li>
            </ul>
            <h3>Built for privacy and compliance</h3>
            <ul>
              <li>Host on-prem in security sensitive environments</li>
              <li>Maintain full control of your data and network traffic</li>
            </ul>
            <h3>Simplify management for admins</h3>
            <ul>
              <li>Automatic de-provisioning with SCIM</li>
              <li>Deployment advice for complex use cases</li>
            </ul>
          </div>
          <div>
            <HubspotForm
              region="na1"
              portalId="23723443"
              formId="76637b95-cef7-4b94-8e7a-411aeec5fbb1"
            />
          </div>
        </div>
      </div>
    </div>
  );
}
