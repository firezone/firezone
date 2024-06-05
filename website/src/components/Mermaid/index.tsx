import React, { useEffect } from "react";
import mermaid from "mermaid";

type MermaidProps = {
  name: string;
  chart: string;
};

mermaid.initialize({
  deterministicIds: true,
  startOnLoad: true,
  theme: "default",
});
console.log("Initializing Mermaid");
mermaid.contentLoaded();

const Mermaid: React.FC<MermaidProps> = ({ name, chart }) => {
  useEffect(() => {}, []);

  return (
    <div className="mermaid" id={name}>
      {chart}
    </div>
  );
};

export default Mermaid;
