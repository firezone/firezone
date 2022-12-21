import React from "react";
import CodeBlock from '@theme/CodeBlock';

export default function InstallBlock() {
  let distinct_id = window.posthog.get_distinct_id()

  return (
    <div>
      <CodeBlock
        language="bash">
        {`bash <(curl -fsSL https://github.com/firezone/firezone/raw/master/scripts/install.sh) ${distinct_id}`}
      </CodeBlock>
    </div>
  );
}
