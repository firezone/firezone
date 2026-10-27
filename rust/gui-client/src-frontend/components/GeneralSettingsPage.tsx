import React, { useId, useState } from "react";
import {
  GeneralSettingsForm,
  GeneralSettingsViewModel,
  Portal,
} from "../generated/bindings";
import Button from "./Button";
import SettingRow from "./SettingRow";
import TextSetting from "./TextSetting";
import { ManagedSelect, ManagedToggleSwitch } from "./ManagedInput";

interface Props {
  settings: GeneralSettingsViewModel | null;
  saveSettings: (settings: GeneralSettingsForm) => void;
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
};

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

  const save = (changes: Partial<GeneralSettingsForm>) =>
    saveSettings({
      start_minimized: saved.start_minimized,
      start_on_login: saved.start_on_login,
      connect_on_start: saved.connect_on_start,
      account_slug: saved.account_slug,
      portal: saved.portal,
      auth_url: saved.auth_url,
      api_url: saved.api_url,
      ...changes,
    });

  // Picking "Custom" brings back the URLs last saved with it.
  const selectPortal = (portal: Portal) => {
    setCustomPicked(portal === "Custom");
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
              save={(account_slug) => save({ account_slug })}
              value={saved.account_slug}
            />

            <SettingRow field inputId={portalInputId} label="Portal">
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
                  save={(auth_url) =>
                    save({ portal, auth_url, api_url: customApiUrl })
                  }
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
                  save={(api_url) =>
                    save({ portal, auth_url: customAuthUrl, api_url })
                  }
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

// Matches the check on the Rust side and in the Apple client.
function isUrl(value: string, protocols: string[]) {
  try {
    const url = new URL(value);
    return url.hostname !== "" && protocols.includes(url.protocol);
  } catch {
    return false;
  }
}
