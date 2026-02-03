import nextConfig from "eslint-config-next";
import coreWebVitals from "eslint-config-next/core-web-vitals";
import typescript from "eslint-config-next/typescript";

// Custom rule to disallow HTML entity apostrophes in JSX
const noHtmlEntityApostrophe = {
  meta: {
    type: "problem",
    docs: {
      description: "Disallow HTML entity apostrophes (&apos; or &#39;) in JSX",
    },
    messages: {
      noEntityApostrophe:
        "Avoid {{ entity }}. You can use a literal ' in JSX instead.",
    },
    schema: [],
  },
  create(context) {
    return {
      JSXText(node) {
        const text = node.raw;
        const patterns = [/&apos;/g, /&#39;/g];

        for (const pattern of patterns) {
          let match;
          while ((match = pattern.exec(text)) !== null) {
            context.report({
              node,
              messageId: "noEntityApostrophe",
              data: { entity: match[0] },
            });
          }
        }
      },
      Literal(node) {
        if (typeof node.value !== "string") return;
        if (!node.parent || node.parent.type !== "JSXAttribute") return;

        const text = node.raw;
        const patterns = [/&apos;/g, /&#39;/g];

        for (const pattern of patterns) {
          let match;
          while ((match = pattern.exec(text)) !== null) {
            context.report({
              node,
              messageId: "noEntityApostrophe",
              data: { entity: match[0] },
            });
          }
        }
      },
    };
  },
};

const eslintConfig = [
  ...nextConfig,
  ...coreWebVitals,
  ...typescript,
  {
    plugins: {
      local: {
        rules: {
          "no-html-entity-apostrophe": noHtmlEntityApostrophe,
        },
      },
    },
    rules: {
      "local/no-html-entity-apostrophe": "error",
    },
  },
];

export default eslintConfig;
