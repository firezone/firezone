"use client";
import { useEffect } from "react";

export default function TermlyContent({ id }) {
  useEffect(() => {
    if (document.getElementById("termly-script")) {
      document.getElementById("termly-script").remove();
    }
    const script = document.createElement("script");
    script.id = "termly-script";
    script.src = "https://app.termly.io/embed-policy.min.js";
    script.async = true;
    document.body.appendChild(script);
  }, []);

  // Termly expects the <div name="> which is not valid HTML according to React.
  // So this file is JSX. Sad face.
  return <div name="termly-embed" data-id={id} data-type="iframe"></div>;
}
