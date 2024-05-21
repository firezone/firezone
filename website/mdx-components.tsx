import type { MDXComponents } from "mdx/types";

export function useMDXComponents(components: MDXComponents): MDXComponents {
  return {
    // Flowbite typography and highlight together create ugly code block
    // offspring, so disable typography for code blocks.
    pre: ({ children }) => (
      <div className="not-format mb-4 lg:mb-8">
        <pre>{children}</pre>
      </div>
    ),
    ...components,
  };
}
