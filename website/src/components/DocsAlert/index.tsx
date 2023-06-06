"use client";
import { Alert as FlowbiteAlert } from "flowbite-react";

export default function Alert({
  children,
  ...props
}: {
  children: React.ReactNode;
}) {
  return <FlowbiteAlert {...props}>{children}</FlowbiteAlert>;
}
