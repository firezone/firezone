import React, { useState } from "react";
import {
  ResourceKind,
  ResourceViewModel,
  SessionViewModel,
} from "../generated/bindings";
import Button from "./Button";
import { STATUS_TEXT, StatusDot } from "./ConnectionStatus";
import RemixIcon from "./RemixIcon";
import ResourceDetails, { ResourceActions } from "./ResourceDetails";

interface ResourcesPageProps extends ResourceActions {
  session: SessionViewModel | null;
  resources: ResourceViewModel[] | null;
  signIn: () => void;
}

export default function ResourcesPage({
  session,
  resources,
  signIn,
  ...actions
}: ResourcesPageProps) {
  // Nothing is known before the first events arrive, which is not worth a flash of either state.
  if (resources === null && session === null) {
    return null;
  }

  if (resources === null && session === "SignedOut") {
    return (
      <Message>
        <ResourcesIcon />
        <p className="text-sm text-body">Sign in to see your Resources.</p>
        <Button onClick={signIn} variant="primary">
          Sign in
        </Button>
      </Message>
    );
  }

  if (resources === null) {
    return (
      <Message>
        <span
          aria-label="Loading"
          className="h-5 w-5 animate-spin rounded-full border-2 border-brand-muted border-t-brand"
          role="status"
        />
      </Message>
    );
  }

  if (resources.length === 0) {
    return (
      <Message>
        <ResourcesIcon />
        <p className="text-sm text-body">
          Your administrator has not given you access to any Resources yet.
        </p>
      </Message>
    );
  }

  return <ResourceBrowser resources={resources} {...actions} />;
}

function ResourcesIcon() {
  return <RemixIcon className="h-8 w-8 text-muted" name="server" />;
}

function Message({ children }: React.PropsWithChildren) {
  return (
    <div className="flex h-full items-center justify-center bg-page p-6">
      <div className="flex max-w-xs flex-col items-center gap-3 text-center">
        {children}
      </div>
    </div>
  );
}

interface ResourceBrowserProps extends ResourceActions {
  resources: ResourceViewModel[];
}

function ResourceBrowser({ resources, ...actions }: ResourceBrowserProps) {
  const [search, setSearch] = useState("");
  const [selectedId, setSelectedId] = useState<string | null>(null);

  const query = search.trim().toLowerCase();
  const matching = resources.filter((resource) => matches(resource, query));
  const selected = resources.find((resource) => resource.id === selectedId);

  return (
    <div className="flex h-full">
      <div className="flex w-64 shrink-0 flex-col border-r border-border bg-surface">
        <div className="relative p-2">
          <RemixIcon
            className="pointer-events-none absolute left-4.5 top-1/2 h-4 w-4 -translate-y-1/2 text-subtle"
            name="search"
          />
          <input
            aria-label="Search Resources"
            className="form-input h-8 pl-8 placeholder:text-subtle"
            onChange={(event) => setSearch(event.target.value)}
            placeholder="Search"
            type="search"
            value={search}
          />
        </div>
        <ResourceList
          onSelect={setSelectedId}
          resources={matching}
          selectedId={selectedId}
        />
      </div>
      <div className="min-w-0 flex-1 overflow-y-auto bg-page [scrollbar-width:thin]">
        {selected ? (
          <ResourceDetails key={selected.id} resource={selected} {...actions} />
        ) : (
          <Message>
            <ResourcesIcon />
            <p className="text-sm text-body">
              Select a Resource to see its details.
            </p>
          </Message>
        )}
      </div>
    </div>
  );
}

function matches({ name, kind }: ResourceViewModel, query: string): boolean {
  const searched = [name];

  if (kind.type === "Dns" || kind.type === "Cidr") {
    searched.push(kind.address, kind.description ?? "");
  }
  if (kind.type !== "DevicePool") {
    searched.push(kind.connection.site ?? "");
  }

  return searched.some((text) => text.toLowerCase().includes(query));
}

function isFavorite({ kind }: ResourceViewModel): boolean {
  return kind.type !== "Internet" && kind.is_favorite;
}

interface ResourceListProps {
  resources: ResourceViewModel[];
  selectedId: string | null;
  onSelect: (resourceId: string) => void;
}

function ResourceList({ resources, selectedId, onSelect }: ResourceListProps) {
  if (resources.length === 0) {
    return (
      <p className="px-4 py-6 text-center text-xs text-subtle">
        No Resources match your search.
      </p>
    );
  }

  const favorites = resources.filter(isFavorite);
  const sections = [
    {
      title: null,
      resources: resources.filter(({ kind }) => kind.type === "Internet"),
    },
    { title: "Favorites", resources: favorites },
    {
      title: favorites.length > 0 ? "Other Resources" : null,
      resources: resources.filter(
        (resource) => resource.kind.type !== "Internet" && !isFavorite(resource)
      ),
    },
  ];

  return (
    <div className="flex-1 overflow-y-auto px-2 pb-2 [scrollbar-width:thin]">
      {sections
        .filter(({ resources }) => resources.length > 0)
        .map(({ title, resources }, index) => (
          <section key={index}>
            {title && (
              <h2 className="px-2 pb-1 pt-3 text-xs font-semibold text-body">
                {title}
              </h2>
            )}
            <ul className="space-y-0.5">
              {resources.map((resource) => (
                <li key={resource.id}>
                  <ResourceRow
                    onSelect={() => onSelect(resource.id)}
                    resource={resource}
                    selected={resource.id === selectedId}
                  />
                </li>
              ))}
            </ul>
          </section>
        ))}
    </div>
  );
}

interface ResourceRowProps {
  resource: ResourceViewModel;
  selected: boolean;
  onSelect: () => void;
}

function ResourceRow({ resource, selected, onSelect }: ResourceRowProps) {
  const { name, kind } = resource;

  return (
    <button
      aria-current={selected ? "true" : undefined}
      className={`nav-item w-full text-left ${selected ? "nav-item-active" : ""}`}
      onClick={onSelect}
      type="button"
    >
      <span className="flex w-3.5 shrink-0 justify-center">
        {kind.type === "DevicePool" ? (
          <RemixIcon className="h-3.5 w-3.5 text-subtle" name="computer" />
        ) : (
          <>
            <StatusDot status={kind.connection.status} />
            <span className="sr-only">
              {STATUS_TEXT[kind.connection.status].label}
            </span>
          </>
        )}
      </span>
      <span className="min-w-0 flex-1">
        <span className="block truncate">{name}</span>
        <span className="block truncate text-xs font-normal text-subtle">
          {summary(kind)}
        </span>
      </span>
      {isFavorite(resource) && (
        <RemixIcon className="h-3.5 w-3.5 text-brand" name="star-fill" />
      )}
    </button>
  );
}

function summary(kind: ResourceKind): string {
  switch (kind.type) {
    case "Dns":
    case "Cidr":
      return kind.address;
    case "Internet":
      return kind.is_enabled ? "All network traffic" : "Disabled";
    case "DevicePool":
      return connectedDevices(kind.devices.length);
  }
}

function connectedDevices(count: number): string {
  if (count === 0) return "No connected devices";
  if (count === 1) return "1 connected device";

  return `${count} connected devices`;
}
