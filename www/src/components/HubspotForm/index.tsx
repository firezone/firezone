import React from 'react';

class HubspotForm extends React.Component<{
  portalId: string;
  formId: string;
  region: string;
}> {
  componentDidMount() {
    const script = document.createElement("script");
    script.src = "https://js.hsforms.net/forms/v2.js";
    document.body.appendChild(script);

    script.addEventListener("load", () => {
      // @ts-ignore
      if (window.hbspt) {
        // @ts-ignore
        window.hbspt.forms.create({
          target: "#hubspot-form",
          ...this.props,
        });
      }
    });
  }

  render() {
    return (
      <div>
        <div id="hubspot-form" />
      </div>
    );
  }
}

export default HubspotForm;
