import React, { useEffect, useId, useState } from "react";
import { GeneralSettingsViewModel, Portal } from "../generated/bindings";
import Button from "./Button";
import SettingRow from "./SettingRow";
import {
  ManagedSelect,
  ManagedTextInput,
  ManagedToggleSwitch,
} from "./ManagedInput";

interface Props {
  settings: GeneralSettingsViewModel | null;
  saveSettings: (settings: GeneralSettingsViewModel) => void;
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
  const [localSettings, setLocalSettings] = useState<GeneralSettingsViewModel>(
    settings ?? defaultSettings
  );

  useEffect(() => {
    setLocalSettings(settings ?? defaultSettings);
  }, [settings]);

  const portalInputId = useId();
  const authUrlInputId = useId();
  const apiUrlInputId = useId();
  const accountSlugInputId = useId();
  const startMinimizedInputId = useId();
  const startOnLoginInputId = useId();
  const connectOnStartInputId = useId();

  return (
    <div className="page">
      <form
        className="max-w-xl space-y-3"
        onSubmit={(event) => {
          event.preventDefault();
          saveSettings(localSettings);
        }}
      >
        <section>
          <h2 className="form-label">Sign-in</h2>
          <div className="panel divide-y divide-border">
            <SettingRow field inputId={accountSlugInputId} label="Account slug">
              <ManagedTextInput
                className="h-8 py-1"
                id={accountSlugInputId}
                managed={localSettings.account_slug_is_managed}
                name="account_slug"
                onChange={(event) =>
                  setLocalSettings({
                    ...localSettings,
                    account_slug: event.target.value,
                  })
                }
                value={localSettings.account_slug}
              />
            </SettingRow>

            <SettingRow field inputId={portalInputId} label="Portal">
              <ManagedSelect
                className="h-8 py-1"
                id={portalInputId}
                managed={
                  localSettings.auth_url_is_managed ||
                  localSettings.api_url_is_managed
                }
                name="portal"
                onChange={(event) =>
                  setLocalSettings(
                    selectPortal(localSettings, event.target.value as Portal)
                  )
                }
                value={localSettings.portal}
              >
                <option value="CloudUs">Firezone Cloud (US)</option>
                <option value="CloudEu">Firezone Cloud (EU)</option>
                <option value="Custom">Custom</option>
              </ManagedSelect>
            </SettingRow>

            {localSettings.portal === "Custom" && (
              <>
                <SettingRow field inputId={authUrlInputId} label="Auth URL">
                  <ManagedTextInput
                    className="h-8 py-1"
                    id={authUrlInputId}
                    managed={localSettings.auth_url_is_managed}
                    name="auth_url"
                    onChange={(event) =>
                      setLocalSettings({
                        ...localSettings,
                        auth_url: event.target.value,
                      })
                    }
                    required
                    value={localSettings.auth_url}
                  />
                </SettingRow>

                <SettingRow field inputId={apiUrlInputId} label="API URL">
                  <ManagedTextInput
                    className="h-8 py-1"
                    id={apiUrlInputId}
                    managed={localSettings.api_url_is_managed}
                    name="api_url"
                    onChange={(event) =>
                      setLocalSettings({
                        ...localSettings,
                        api_url: event.target.value,
                      })
                    }
                    required
                    value={localSettings.api_url}
                  />
                </SettingRow>
              </>
            )}
          </div>
        </section>

        <section>
          <h2 className="form-label">Startup</h2>
          <div className="panel divide-y divide-border">
            <SettingRow inputId={startMinimizedInputId} label="Start minimized">
              <ManagedToggleSwitch
                checked={localSettings.start_minimized}
                id={startMinimizedInputId}
                managed={false}
                name="start_minimized"
                onChange={(checked) =>
                  setLocalSettings({
                    ...localSettings,
                    start_minimized: checked,
                  })
                }
              />
            </SettingRow>

            <SettingRow inputId={startOnLoginInputId} label="Start on login">
              <ManagedToggleSwitch
                checked={localSettings.start_on_login}
                id={startOnLoginInputId}
                managed={false}
                name="start_on_login"
                onChange={(checked) =>
                  setLocalSettings({
                    ...localSettings,
                    start_on_login: checked,
                  })
                }
              />
            </SettingRow>

            <SettingRow
              inputId={connectOnStartInputId}
              label="Connect on start"
            >
              <ManagedToggleSwitch
                checked={localSettings.connect_on_start}
                id={connectOnStartInputId}
                managed={localSettings.connect_on_start_is_managed}
                name="connect-on-start"
                onChange={(checked) =>
                  setLocalSettings({
                    ...localSettings,
                    connect_on_start: checked,
                  })
                }
              />
            </SettingRow>
          </div>
        </section>

        <div className="flex justify-end gap-2 border-t border-border pt-3">
          <Button onClick={resetSettings} type="reset">
            Reset to Defaults
          </Button>
          <Button type="submit" variant="primary">
            Apply
          </Button>
        </div>
      </form>
    </div>
  );
}

// Picking "Custom" fills in the URLs last saved with it, so switching to a cloud portal and
// back does not make the user type them again.
function selectPortal(
  settings: GeneralSettingsViewModel,
  portal: Portal
): GeneralSettingsViewModel {
  if (portal !== "Custom") {
    return { ...settings, portal };
  }

  return {
    ...settings,
    portal,
    auth_url: settings.custom_auth_url,
    api_url: settings.custom_api_url,
  };
}
