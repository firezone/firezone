import React, { useId, useState } from "react";
import {
  ClientSettingsForm,
  GeneralSettingsViewModel,
  Portal,
  SignedInWithViewModel,
} from "../generated/bindings";
import Button from "./Button";
import SettingRow from "./SettingRow";
import TextSetting from "./TextSetting";
import { ManagedSelect, ManagedToggleSwitch } from "./ManagedInput";

interface Props {
  settings: GeneralSettingsViewModel | null;
  saveSettings: (settings: ClientSettingsForm) => void;
  resetSettings: () => void;
}

const defaultSettings: GeneralSettingsViewModel = {
  start_minimized: true,
  account_slug: "",
  connect_on_start: false,
  start_on_login: false,
  account_slug_is_managed: false,
  connect_on_start_is_managed: false,
  portal: "Custom",
  auth_url: "",
  auth_url_is_managed: false,
  api_url: "",
  api_url_is_managed: false,
  custom_auth_url: "",
  custom_api_url: "",
  signed_in_with: null,
};

type Drafts = Partial<Record<"account_slug" | "auth_url" | "api_url", string>>;

export default function GeneralSettingsPage({
  settings,
  saveSettings,
  resetSettings,
}: Props) {
  const saved = settings ?? defaultSettings;

  // Custom with a cloud portal's URLs is saved as that cloud portal, so the page keeps the
  // choice until the user enters URLs of their own.
  const [customPicked, setCustomPicked] = useState(false);
  const portal = customPicked ? "Custom" : saved.portal;
  const customAuthUrl =
    saved.portal === "Custom" ? saved.auth_url : saved.custom_auth_url;
  const customApiUrl =
    saved.portal === "Custom" ? saved.api_url : saved.custom_api_url;

  const [drafts, setDrafts] = useState<Drafts>({});
  const updateDraft = (field: keyof Drafts) => (draft: string | null) =>
    setDrafts((drafts) =>
      (drafts[field] ?? null) === draft
        ? drafts
        : { ...drafts, [field]: draft ?? undefined }
    );

  const savedSignIn: SignedInWithViewModel = {
    account_slug: saved.account_slug,
    portal: saved.portal,
    auth_url: saved.auth_url,
    api_url: saved.api_url,
  };
  const draftSignIn: SignedInWithViewModel = {
    account_slug: drafts.account_slug ?? saved.account_slug,
    portal,
    auth_url: drafts.auth_url ?? customAuthUrl,
    api_url: drafts.api_url ?? customApiUrl,
  };
  const signedInWith = saved.signed_in_with;
  const signInPending =
    signedInWith !== null &&
    (differs(savedSignIn, signedInWith) || differs(draftSignIn, signedInWith));

  const save = (changes: Partial<ClientSettingsForm>) => saveSettings(changes);

  // Picking "Custom" brings back the URLs last saved with it.
  const selectPortal = (portal: Portal) => {
    setCustomPicked(portal === "Custom");
    setDrafts(({ account_slug }) => ({ account_slug }));
    save(
      portal === "Custom"
        ? { portal, auth_url: customAuthUrl, api_url: customApiUrl }
        : { portal }
    );
  };

  const portalInputId = useId();
  const startMinimizedInputId = useId();
  const startOnLoginInputId = useId();
  const connectOnStartInputId = useId();

  return (
    <div className="page">
      <div className="max-w-xl space-y-3">
        <section>
          <h2 className="form-label">Sign-in</h2>
          <div className="panel divide-y divide-border">
            <TextSetting
              label="Account slug"
              managed={saved.account_slug_is_managed}
              name="account_slug"
              onDraftChange={updateDraft("account_slug")}
              save={(account_slug) => save({ account_slug })}
              value={saved.account_slug}
            />

            <SettingRow field inputId={portalInputId} label="Control plane">
              <ManagedSelect
                className="h-8 py-1"
                id={portalInputId}
                managed={saved.auth_url_is_managed || saved.api_url_is_managed}
                name="portal"
                onChange={(event) => selectPortal(event.target.value as Portal)}
                value={portal}
              >
                <option value="CloudUs">Firezone Cloud (US)</option>
                <option value="CloudEu">Firezone Cloud (EU)</option>
                <option value="Custom">Custom</option>
              </ManagedSelect>
            </SettingRow>

            {portal === "Custom" && (
              <>
                <TextSetting
                  label="Auth URL"
                  managed={saved.auth_url_is_managed}
                  name="auth_url"
                  onDraftChange={updateDraft("auth_url")}
                  save={(auth_url) => save({ portal, auth_url })}
                  validate={(url) =>
                    isUrl(url, ["http:", "https:"])
                      ? null
                      : "Enter a valid http:// or https:// URL"
                  }
                  value={customAuthUrl}
                />

                <TextSetting
                  label="API URL"
                  managed={saved.api_url_is_managed}
                  name="api_url"
                  onDraftChange={updateDraft("api_url")}
                  save={(api_url) => save({ portal, api_url })}
                  validate={(url) =>
                    isUrl(url, ["ws:", "wss:"])
                      ? null
                      : "Enter a valid ws:// or wss:// URL"
                  }
                  value={customApiUrl}
                />
              </>
            )}
          </div>
          {signInPending && (
            <p className="mt-1.5 text-xs text-subtle">
              Sign out and sign in again after changing the account slug or
              control plane.
            </p>
          )}
        </section>

        <section>
          <h2 className="form-label">Startup</h2>
          <div className="panel divide-y divide-border">
            <SettingRow inputId={startMinimizedInputId} label="Start minimized">
              <ManagedToggleSwitch
                checked={saved.start_minimized}
                id={startMinimizedInputId}
                managed={false}
                name="start_minimized"
                onChange={(start_minimized) => save({ start_minimized })}
              />
            </SettingRow>

            <SettingRow inputId={startOnLoginInputId} label="Start on login">
              <ManagedToggleSwitch
                checked={saved.start_on_login}
                id={startOnLoginInputId}
                managed={false}
                name="start_on_login"
                onChange={(start_on_login) => save({ start_on_login })}
              />
            </SettingRow>

            <SettingRow
              inputId={connectOnStartInputId}
              label="Connect on start"
            >
              <ManagedToggleSwitch
                checked={saved.connect_on_start}
                id={connectOnStartInputId}
                managed={saved.connect_on_start_is_managed}
                name="connect-on-start"
                onChange={(connect_on_start) => save({ connect_on_start })}
              />
            </SettingRow>
          </div>
        </section>

        <div className="flex justify-end border-t border-border pt-3">
          <Button
            onClick={() => {
              setCustomPicked(false);
              resetSettings();
            }}
            type="button"
          >
            Reset to Defaults
          </Button>
        </div>
      </div>
    </div>
  );
}

// Cloud portals compare by name, Custom ones by their URLs.
function differs(
  signIn: SignedInWithViewModel,
  signedInWith: SignedInWithViewModel
) {
  if (signIn.account_slug.trim() !== signedInWith.account_slug) {
    return true;
  }

  if (signIn.portal !== "Custom") {
    return signIn.portal !== signedInWith.portal;
  }

  return (
    normalizeUrl(signIn.auth_url) !== normalizeUrl(signedInWith.auth_url) ||
    normalizeUrl(signIn.api_url) !== normalizeUrl(signedInWith.api_url)
  );
}

function normalizeUrl(value: string) {
  try {
    return new URL(value).href;
  } catch {
    return value;
  }
}

// Matches the check on the Rust side and in the Apple client.
function isUrl(value: string, protocols: string[]) {
  try {
    const url = new URL(value);
    return url.hostname !== "" && protocols.includes(url.protocol);
  } catch {
    return false;
  }
}
