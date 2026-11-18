import React from "react";
import { ConnectionStatus } from "../generated/bindings";

export const STATUS_TEXT: Record<
  ConnectionStatus,
  { label: string; explanation: string }
> = {
  Online: {
    label: "Connected",
    explanation: "Using a healthy Gateway in this Site.",
  },
  Unknown: {
    label: "No activity",
    explanation:
      "No connection has been attempted yet. Access the Resource to connect.",
  },
  Offline: {
    label: "Offline",
    explanation: "No healthy Gateways are online in this Site.",
  },
};

const STATUS_COLOR: Record<ConnectionStatus, string> = {
  Online: "bg-success",
  Unknown: "bg-neutral-status",
  Offline: "bg-danger",
};

export function StatusDot({ status }: { status: ConnectionStatus }) {
  return (
    <span
      aria-hidden="true"
      className={`inline-block h-2 w-2 shrink-0 rounded-full ${STATUS_COLOR[status]}`}
    />
  );
}
