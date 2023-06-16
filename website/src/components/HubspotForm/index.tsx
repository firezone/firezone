"use client";
import React from "react";

const meta = {
  title: "Firezone • Open Source Remote Access",
  description: "Firezone • Newsletter Signup",
};

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
      <div className="border border-gray-200 dark:border-gray-700 rounded-lg p-4">
        <div id="hubspot-form" />
      </div>
    );
  }
}

export default HubspotForm;
