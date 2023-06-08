"use client";
import { Alert as FlowbiteAlert } from "flowbite-react";
import {
  InformationCircleIcon,
  ExclamationCircleIcon,
  ExclamationTriangleIcon,
} from "@heroicons/react/24/outline";

function icon(color: string) {
  switch (color) {
    case "info":
      return (
        <span>
          <InformationCircleIcon className="inline-block w-5 h-5 mr-2" />
          <span className="text-xs font-bold">INFO</span>
        </span>
      );
    case "warning":
      return (
        <span>
          <ExclamationCircleIcon className="inline-block w-5 h-5 mr-2" />
          <span className="text-xs font-bold">WARNING</span>
        </span>
      );
    case "danger":
      return (
        <span>
          <ExclamationTriangleIcon className="inline-block w-5 h-5 mr-2" />
          <span className="text-xs font-bold">DANGER</span>
        </span>
      );
    default:
      return null;
  }
}

export default function Alert({
  children,
  color,
}: {
  children: React.ReactNode;
  color: string;
}) {
  return (
    <div className="mb-4">
      <FlowbiteAlert color={color}>
        <span>
          {icon(color)}
          {children}
        </span>
      </FlowbiteAlert>
    </div>
  );
}
