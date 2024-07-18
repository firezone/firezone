import type { MDXComponents } from "mdx/types";
import Clipboard from "@/components/Clipboard";
import { useState, useRef, useEffect } from "react";

export function useMDXComponents(components: MDXComponents): MDXComponents {
  return {
    pre: ({ children }) => {
      const [isHovered, setIsHovered] = useState(false);
      const [codeString, setCodeString] = useState("");
      const preRef = useRef<HTMLDivElement>(null);

      useEffect(() => {
        if (preRef.current) {
          const codeElement = preRef.current.querySelector("code");
          if (codeElement) {
            setCodeString(codeElement.innerText);
          }
        }
      }, []);

      return (
        <div
          // Flowbite typography and highlight together create ugly code block
          // offspring, so disable typography for code blocks.
          className="not-format mb-4 lg:mb-8 relative"
          onMouseEnter={() => setIsHovered(true)}
          onMouseLeave={() => setIsHovered(false)}
          ref={preRef}
        >
          <pre>
            {children}
            {isHovered && <Clipboard valueToCopy={codeString} />}
          </pre>
        </div>
      );
    },
    ...components,
  };
}
