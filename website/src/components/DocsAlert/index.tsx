"use client";
import {
  HiOutlineInformationCircle,
  HiOutlineExclamationCircle,
  HiOutlineExclamationTriangle,
} from "react-icons/hi2";

export default function Alert({
  html,
  color,
}: {
  html: string;
  color: string;
}) {
  switch (color) {
    case "info":
      return (
        <div className="mb-4 p-3 flex items-center rounded border bg-neutral-100 text-neutral-800 border-neutral-200">
          <HiOutlineInformationCircle className="flex-none w-5 h-5 mr-2" />
          {/* ReactMarkdown wraps this in a <p> tag if we wrap {children} as ReactNode, so we need to use string here instead. */}
          <span
            className="format-none text-sm"
            dangerouslySetInnerHTML={{ __html: html }}
          />
        </div>
      );
    case "warning":
      return (
        <div className="mb-4 p-3 flex items-center rounded border bg-accent-100 text-accent-800 border-accent-200">
          <HiOutlineExclamationCircle className="flex-none w-5 h-5 mr-2" />
          {/* ReactMarkdown wraps this in a <p> tag if we wrap {children} as ReactNode, so we need to use string here instead. */}
          <span
            className="format-none text-sm"
            dangerouslySetInnerHTML={{ __html: html }}
          />
        </div>
      );
    case "danger":
      return (
        <div className="mb-4 p-3 flex items-center rounded border bg-primary-100 text-primary-800 border-primary-200">
          <HiOutlineExclamationTriangle className="flex-none w-5 h-5 mr-2" />
          {/* ReactMarkdown wraps this in a <p> tag if we wrap {children} as ReactNode, so we need to use string here instead. */}
          <span
            className="format-none text-sm"
            dangerouslySetInnerHTML={{ __html: html }}
          />
        </div>
      );
  }
}
