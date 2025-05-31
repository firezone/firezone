import React, { useEffect, useState } from "react";
import { Button, TextInput, Label, TextInputProps, Tooltip } from "flowbite-react";

export interface Settings {
  auth_url: string;
  auth_url_is_managed: boolean;
  api_url: string;
  api_url_is_managed: boolean;
  log_filter: string;
  log_filter_is_managed: boolean;
}

interface SettingsPageProps {
  settings: Settings | null;
  saveSettings: (settings: Settings) => void;
  resetSettings: () => void;
}

export default function SettingsPage({
  settings,
  saveSettings,
  resetSettings,
}: SettingsPageProps) {
  // Local settings can be edited without affecting the global state.
  const [localSettings, setLocalSettings] = useState<Settings>(
    settings ?? {
      api_url: "",
      api_url_is_managed: false,
      auth_url: "",
      auth_url_is_managed: false,
      log_filter: "",
      log_filter_is_managed: false,
    }
  );

  useEffect(() => {
    setLocalSettings(
      settings ?? {
        api_url: "",
        api_url_is_managed: false,
        auth_url: "",
        auth_url_is_managed: false,
        log_filter: "",
        log_filter_is_managed: false,
      }
    );
  }, [settings]);

  return (
    <div className="container mx-auto p-4">
      <div className="pb-2">
        <h2 className="text-xl font-semibold mb-4">Advanced Settings</h2>
      </div>

      <p className="text-neutral-900 mb-6">
        <strong>WARNING</strong>: These settings are intended for internal
        debug purposes <strong>only</strong>. Changing these is not supported
        and will disrupt access to your resources.
      </p>

      <form
        onSubmit={(e) => {
          e.preventDefault();
          saveSettings(localSettings);
        }}
        className="max-w mx-auto flex flex-col gap-2"
      >
        <div>
          <Label className="text-neutral-600" htmlFor="auth-base-url-input">Auth Base URL</Label>
          <ManagedTextInput
            name="auth_base_url"
            id="auth-base-url-input"
            managed={localSettings.auth_url_is_managed}
            value={localSettings.auth_url}
            onChange={(e) =>
              setLocalSettings({
                ...localSettings,
                auth_url: e.target.value,
              })
            }
            required
          />
        </div>

        <div>
          <Label className="text-neutral-600" htmlFor="api-url-input">API URL</Label>
          <ManagedTextInput
            name="api_url"
            id="api-url-input"
            managed={localSettings.api_url_is_managed}
            value={localSettings.api_url}
            onChange={(e) =>
              setLocalSettings({
                ...localSettings,
                api_url: e.target.value,
              })
            }
            required
          />
        </div>

        <div>
          <Label className="text-neutral-600" htmlFor="log-filter-input">Log Filter</Label>
          <ManagedTextInput
            name="log_filter"
            id="log-filter-input"
            managed={localSettings.log_filter_is_managed}
            value={localSettings.log_filter}
            onChange={(e) =>
              setLocalSettings({
                ...localSettings,
                log_filter: e.target.value,
              })
            }
            required
          />
        </div>

        <div className="flex justify-end gap-4 mt-4">
          <Button
            type="reset"
            onClick={resetSettings}
            color="alternative"
          >
            Reset to Defaults
          </Button>
          <Button type="submit">Apply</Button>
        </div>
      </form>
    </div>
  );
}

function ManagedTextInput(props: TextInputProps & { managed: boolean }) {
  let { managed, ...inputProps } = props;

  if (managed) {
    return <Tooltip content="This setting is managed by your organisation." clearTheme={{target: true}}>
      <TextInput {...inputProps} disabled={true} />
    </Tooltip>
  } else {
    return <TextInput {...inputProps} />
  }
}
