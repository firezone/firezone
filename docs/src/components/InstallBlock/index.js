import React from "react";
import CodeBlock from '@theme/CodeBlock';
import BrowserOnly from '@docusaurus/BrowserOnly';

export default function InstallBlock() {
  return (
    <BrowserOnly fallback={<div>Loading...</div>}>
      {() => {
        if (window.posthog && typeof window.posthog.get_distinct_id === "function") {
          const distinct_id = window.posthog.get_distinct_id()
        } else {
          const distinct_id = "posthog-blocked"
        }

        return (
          <CodeBlock language="bash">
            {`bash <(curl -fsSL https://github.com/firezone/firezone/raw/master/scripts/install.sh) ${distinct_id}`}
          </CodeBlock>
        )
      }}
    </BrowserOnly>
  )
}
