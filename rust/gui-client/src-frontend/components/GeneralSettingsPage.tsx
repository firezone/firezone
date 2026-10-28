import React, { useId, useState } from "react";
import {
  ClientSettingsForm,
  ControlPlane,
  GeneralSettingsViewModel,
  SignInSettingsViewModel,
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
  control_plane: "Custom",
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

  // Custom with a cloud control plane's URLs is saved as that control plane, so the page
  // keeps the choice until the user enters URLs of their own.
  const [customPicked, setCustomPicked] = useState(false);
  const control_plane = customPicked ? "Custom" : saved.control_plane;
  const customAuthUrl =
    saved.control_plane === "Custom" ? saved.auth_url : saved.custom_auth_url;
  const customApiUrl =
    saved.control_plane === "Custom" ? saved.api_url : saved.custom_api_url;

  const [drafts, setDrafts] = useState<Drafts>({});
  const updateDraft = (field: keyof Drafts) => (draft: string | null) =>
    setDrafts((drafts) =>
      (drafts[field] ?? null) === draft
        ? drafts
        : { ...drafts, [field]: draft ?? undefined }
    );

  const savedSignIn: SignInSettingsViewModel = {
    account_slug: saved.account_slug,
    control_plane: saved.control_plane,
    auth_url: saved.auth_url,
    api_url: saved.api_url,
  };
  const draftSignIn: SignInSettingsViewModel = {
    account_slug: drafts.account_slug ?? saved.account_slug,
    control_plane,
    auth_url: drafts.auth_url ?? customAuthUrl,
    api_url: drafts.api_url ?? customApiUrl,
  };
  const signedInWith = saved.signed_in_with;
  const signInPending =
    signedInWith !== null &&
    (differs(savedSignIn, signedInWith) || differs(draftSignIn, signedInWith));

  const save = (changes: Partial<ClientSettingsForm>) => saveSettings(changes);

  // Picking "Custom" brings back the URLs last saved with it.
  const selectControlPlane = (control_plane: ControlPlane) => {
    setCustomPicked(control_plane === "Custom");
    setDrafts(({ account_slug }) => ({ account_slug }));
    save(
      control_plane === "Custom"
        ? { control_plane, auth_url: customAuthUrl, api_url: customApiUrl }
        : { control_plane }
    );
  };

  const controlPlaneInputId = useId();
  const startMinimizedInputId = useId();
  const startOnLoginInputId = useId();
  const connectOnStartInputId = useId();

  return (
    <div className="page">
      <div className="space-y-5">
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

            <SettingRow
              field
              inputId={controlPlaneInputId}
              label="Control plane"
            >
              <ManagedSelect
                id={controlPlaneInputId}
                managed={saved.auth_url_is_managed || saved.api_url_is_managed}
                name="control_plane"
                onChange={(event) =>
                  selectControlPlane(event.target.value as ControlPlane)
                }
                value={control_plane}
              >
                <option value="CloudUs">Firezone Cloud (US)</option>
                <option value="CloudEu">Firezone Cloud (EU)</option>
                <option value="Custom">Custom</option>
              </ManagedSelect>
            </SettingRow>

            {control_plane === "Custom" && (
              <>
                <TextSetting
                  label="Auth URL"
                  managed={saved.auth_url_is_managed}
                  name="auth_url"
                  onDraftChange={updateDraft("auth_url")}
                  save={(auth_url) => save({ control_plane, auth_url })}
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
                  save={(api_url) => save({ control_plane, api_url })}
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
            <SettingRow
              field
              inputId={startMinimizedInputId}
              label="Start minimized"
            >
              <ManagedToggleSwitch
                checked={saved.start_minimized}
                id={startMinimizedInputId}
                managed={false}
                name="start_minimized"
                onChange={(start_minimized) => save({ start_minimized })}
              />
            </SettingRow>

            <SettingRow
              field
              inputId={startOnLoginInputId}
              label="Start on login"
            >
              <ManagedToggleSwitch
                checked={saved.start_on_login}
                id={startOnLoginInputId}
                managed={false}
                name="start_on_login"
                onChange={(start_on_login) => save({ start_on_login })}
              />
            </SettingRow>

            <SettingRow
              field
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

// Cloud control planes compare by name, Custom ones by their URLs.
function differs(
  signIn: SignInSettingsViewModel,
  signedInWith: SignInSettingsViewModel
) {
  if (signIn.account_slug.trim() !== signedInWith.account_slug) {
    return true;
  }

  if (signIn.control_plane !== "Custom") {
    return signIn.control_plane !== signedInWith.control_plane;
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
