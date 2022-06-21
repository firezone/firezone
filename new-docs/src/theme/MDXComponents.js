import React from "react";
// Import the original mapper
import MDXComponents from "@theme-original/MDXComponents";
import AccentBlock from "@site/src/components/AccentBlock";
import Feedback from "@site/src/components/Feedback";

export default {
  // Re-use the default mapping
  ...MDXComponents,
  // Map the "highlight" tag to our <Highlight /> component!
  // `Highlight` will receive all props that were passed to `highlight` in MDX
  accentblock: AccentBlock,
  feedback: Feedback,
};
