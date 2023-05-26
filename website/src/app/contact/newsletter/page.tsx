import HubspotForm from "@/components/HubspotForm";

export default function Page() {
  return (
    <div>
      <div className="hero shadow--lw">
        <div className="container">
          <h1 className="hero__title">Firezone Product Newsletter</h1>
          <p>
            Sign up below to receive product and security updates from the
            Firezone team.
          </p>
        </div>
      </div>

      <center>
        <h2 className="margin-vert--xl">Sign Up Form</h2>
      </center>

      <div className="container">
        <div className="row">
          <div className="col col--12">
            <HubspotForm
              region="na1"
              portalId="23723443"
              formId="a45bf30a-3aca-4523-9bc8-7dc2dc3f6176"
            />
          </div>
        </div>
      </div>
    </div>
  );
}
