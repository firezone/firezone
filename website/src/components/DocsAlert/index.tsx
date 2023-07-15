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
      return InformationCircleIcon;
    case "warning":
      return ExclamationCircleIcon;
    case "danger":
      return ExclamationTriangleIcon;
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
      <FlowbiteAlert color={color} icon={icon(color)}>
        {children}
      </FlowbiteAlert>
    </div>
  );
}
