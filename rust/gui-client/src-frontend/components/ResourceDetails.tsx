import { openUrl } from "@tauri-apps/plugin-opener";
import React, { useEffect, useId, useState } from "react";
import {
  ConnectedDevice,
  Connection,
  ResourceKind,
  ResourceViewModel,
} from "../generated/bindings";
import { STATUS_TEXT, StatusDot } from "./ConnectionStatus";
import { ManagedToggleSwitch } from "./ManagedInput";
import RemixIcon from "./RemixIcon";

const KIND_TEXT: Record<ResourceKind["type"], string> = {
  Dns: "DNS Resource",
  Cidr: "CIDR Resource",
  Internet: "Internet",
  DevicePool: "Device pool",
};

export interface ResourceActions {
  setFavorite: (resourceId: string, favorite: boolean) => void;
  setInternetResourceEnabled: (enabled: boolean) => void;
  copy: (text: string) => void;
}

interface ResourceDetailsProps extends ResourceActions {
  resource: ResourceViewModel;
}

export default function ResourceDetails({
  resource,
  setFavorite,
  setInternetResourceEnabled,
  copy,
}: ResourceDetailsProps) {
  const { id, name, kind } = resource;
  const internetResourceInputId = useId();

  return (
    <div className="space-y-4 p-5">
      <header className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <h2 className="break-words text-base font-semibold tracking-tight text-heading">
            {name}
          </h2>
          <p className="mt-0.5 text-xs text-subtle">{KIND_TEXT[kind.type]}</p>
        </div>
        {kind.type !== "Internet" && (
          <FavoriteButton
            favorite={kind.is_favorite}
            setFavorite={(favorite) => setFavorite(id, favorite)}
          />
        )}
      </header>

      <Section title="Resource">
        <Field label="Name">{name}</Field>
        {(kind.type === "Dns" || kind.type === "Cidr") && (
          <>
            <Field label="Address">
              <span className="min-w-0 flex-1 wrap-anywhere font-mono text-xs leading-5">
                {kind.address}
              </span>
              <CopyButton copy={copy} label="address" value={kind.address} />
            </Field>
            {kind.description !== null && (
              <Field label="Description">
                <Description text={kind.description} />
              </Field>
            )}
          </>
        )}
        {kind.type === "Internet" && (
          <>
            <Field label="Description">All network traffic</Field>
            <Field inputId={internetResourceInputId} label="Enabled">
              <span className="ml-auto">
                <ManagedToggleSwitch
                  checked={kind.is_enabled}
                  id={internetResourceInputId}
                  managed={false}
                  onChange={setInternetResourceEnabled}
                />
              </span>
            </Field>
          </>
        )}
      </Section>

      {kind.type === "DevicePool" ? (
        <ConnectedDevices copy={copy} devices={kind.devices} />
      ) : (
        <ConnectionSection connection={kind.connection} />
      )}
    </div>
  );
}

interface FavoriteButtonProps {
  favorite: boolean;
  setFavorite: (favorite: boolean) => void;
}

function FavoriteButton({ favorite, setFavorite }: FavoriteButtonProps) {
  const label = favorite ? "Remove from favorites" : "Add to favorites";

  return (
    <button
      aria-label={label}
      className="icon-button -mr-1 -mt-1 shrink-0"
      onClick={() => setFavorite(!favorite)}
      title={label}
      type="button"
    >
      <RemixIcon
        className={`h-4.5 w-4.5 ${favorite ? "text-brand" : ""}`}
        name={favorite ? "star-fill" : "star"}
      />
    </button>
  );
}

function ConnectionSection({ connection }: { connection: Connection }) {
  const { label, explanation } = STATUS_TEXT[connection.status];

  return (
    <Section title="Connection">
      {connection.site !== null && (
        <Field label="Site">{connection.site}</Field>
      )}
      <Field label="Status">
        <div>
          <p className="flex items-center gap-2 font-medium">
            <StatusDot status={connection.status} />
            {label}
          </p>
          <p className="mt-1 text-xs text-body">{explanation}</p>
        </div>
      </Field>
    </Section>
  );
}

interface ConnectedDevicesProps {
  devices: ConnectedDevice[];
  copy: (text: string) => void;
}

function ConnectedDevices({ devices, copy }: ConnectedDevicesProps) {
  return (
    <section>
      <h3 className="form-label">Connected devices</h3>
      {devices.length === 0 ? (
        <p className="panel px-4 py-2.5 text-sm text-subtle">
          No connected devices
        </p>
      ) : (
        <ul className="space-y-2">
          {devices.map((device) => (
            <li key={device.client_id}>
              <Device copy={copy} device={device} />
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

interface DeviceProps {
  device: ConnectedDevice;
  copy: (text: string) => void;
}

function Device({ device, copy }: DeviceProps) {
  const [expanded, setExpanded] = useState(false);

  const fields = [
    { label: "IPv4", value: device.tunnel_ipv4 },
    { label: "IPv6", value: device.tunnel_ipv6 },
    { label: "Client", value: device.client_name },
    { label: "Client ID", value: device.client_id },
  ];

  return (
    <div className="panel">
      <div className="flex items-center gap-1 px-2 py-1">
        <button
          aria-expanded={expanded}
          className="nav-item min-w-0 flex-1 text-left"
          onClick={() => setExpanded(!expanded)}
          type="button"
        >
          <RemixIcon
            className={`h-4 w-4 text-subtle ${expanded ? "" : "-rotate-90"}`}
            name="arrow-down"
          />
          <span className="truncate font-mono text-xs text-heading">
            {device.hostname}
          </span>
        </button>
        <CopyButton copy={copy} label="hostname" value={device.hostname} />
      </div>
      {expanded && (
        <dl className="divide-y divide-border border-t border-border">
          {fields.map(({ label, value }) => (
            <Field key={label} label={label}>
              <span className="min-w-0 flex-1 wrap-anywhere font-mono text-xs leading-5">
                {value}
              </span>
              <CopyButton copy={copy} label={label} value={value} />
            </Field>
          ))}
        </dl>
      )}
    </div>
  );
}

function Section({
  title,
  children,
}: React.PropsWithChildren<{ title: string }>) {
  return (
    <section>
      <h3 className="form-label">{title}</h3>
      <dl className="panel divide-y divide-border">{children}</dl>
    </section>
  );
}

interface FieldProps extends React.PropsWithChildren {
  label: string;
  inputId?: string;
}

function Field({ label, inputId, children }: FieldProps) {
  return (
    <div className="flex items-start gap-3 py-2.5 pl-4 pr-2">
      <dt className="w-20 shrink-0 text-sm text-body">
        {inputId ? <label htmlFor={inputId}>{label}</label> : label}
      </dt>
      <dd className="flex min-w-0 flex-1 items-start gap-2 pr-2 text-sm text-heading">
        {children}
      </dd>
    </div>
  );
}

function Description({ text }: { text: string }) {
  if (!isWebUrl(text)) {
    return <span className="wrap-anywhere">{text}</span>;
  }

  return (
    <button
      className="wrap-anywhere text-left text-brand hover:text-brand-dark hover:underline"
      onClick={() =>
        openUrl(text).catch((error) =>
          console.error("Failed to open Resource description", error)
        )
      }
      role="link"
      type="button"
    >
      {text}
      <RemixIcon className="ml-1 h-3.5 w-3.5" name="external-link" />
    </button>
  );
}

function isWebUrl(text: string): boolean {
  try {
    const { protocol } = new URL(text);

    return protocol === "http:" || protocol === "https:";
  } catch {
    return false;
  }
}

interface CopyButtonProps {
  label: string;
  value: string;
  copy: (text: string) => void;
}

function CopyButton({ label, value, copy }: CopyButtonProps) {
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    if (!copied) return;

    const timeout = setTimeout(() => setCopied(false), 1500);
    return () => clearTimeout(timeout);
  }, [copied]);

  return (
    <button
      aria-label={`Copy ${label}`}
      className="icon-button -my-1.5 -mr-2 shrink-0"
      onClick={() => {
        copy(value);
        setCopied(true);
      }}
      title="Copy"
      type="button"
    >
      <RemixIcon
        className={`h-4 w-4 ${copied ? "text-success" : ""}`}
        name={copied ? "check" : "copy"}
      />
    </button>
  );
}
