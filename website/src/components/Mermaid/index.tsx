import React, { useEffect } from "react";
import mermaid from "mermaid";

mermaid.initialize({
  startOnLoad: true,
  theme: "default",
});

type MermaidProps = {
  name: string;
  chart: string;
};

const Mermaid: React.FC<MermaidProps> = ({ name, chart }) => {
  useEffect(() => {
    mermaid.contentLoaded();
  }, []);

  return (
    <div className="mermaid" id={name}>
      {chart}
    </div>
  );
};

export default Mermaid;
