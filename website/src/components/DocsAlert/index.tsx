"use client";
import { Alert as FlowbiteAlert } from "flowbite-react";
import {
  HiInformationCircle,
  HiExclamationCircle,
  HiExclamationTriangle,
} from "react-icons/hi2";

function icon(color: string) {
  switch (color) {
    case "info":
      return HiInformationCircle;
    case "warning":
      return HiExclamationCircle;
    case "danger":
      return HiExclamationTriangle;
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
