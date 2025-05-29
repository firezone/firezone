import React, { useEffect, useState } from "react";
import { Button, TextInput, Label, TextInputProps, Tooltip } from "flowbite-react";
import PrimaryButton from "./PrimaryButton";

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
        onSubmit={() => saveSettings(localSettings)}
        className="max-w-md mx-auto flex flex-col gap-2"
      >
        <div>
          <Label className="text-neutral-600" htmlFor="auth-base-url-input">Auth Base URL</Label>
          <TextInputWithTooltipWhenDisabled
            name="auth_base_url"
            id="auth-base-url-input"
            disabled={localSettings.auth_url_is_managed}
            disabledTooltip="This setting is managed by your organisation."
            value={localSettings.auth_url}
            onChange={(e) =>
              setLocalSettings({
                ...localSettings,
                auth_url: e.target.value,
              })
            }
            placeholder=" "
            required
          />
        </div>

        <div>
          <Label className="text-neutral-600" htmlFor="api-url-input">API URL</Label>
          <TextInputWithTooltipWhenDisabled
            name="api_url"
            id="api-url-input"
            disabled={localSettings.api_url_is_managed}
            disabledTooltip="This setting is managed by your organisation."
            value={localSettings.api_url}
            onChange={(e) =>
              setLocalSettings({
                ...localSettings,
                api_url: e.target.value,
              })
            }
            placeholder=" "
            required
          />
        </div>

        <div>
          <Label className="text-neutral-600" htmlFor="log-filter-input">Log Filter</Label>
          <TextInputWithTooltipWhenDisabled
            name="log_filter"
            id="log-filter-input"
            disabled={localSettings.log_filter_is_managed}
            disabledTooltip="This setting is managed by your organisation."
            value={localSettings.log_filter}
            onChange={(e) =>
              setLocalSettings({
                ...localSettings,
                log_filter: e.target.value,
              })
            }
            placeholder=" "
            required
          />
        </div>

        <div className="inline-flex w-full justify-between mt-4">
          <Button
            type="reset"
            onClick={resetSettings}
            color=""
            className="bg-neutral-400 hover:bg-neutral-700 font-medium rounded-md text-md px-5 py-1.5"
          >
            Reset to Defaults
          </Button>
          <PrimaryButton type="submit">Apply</PrimaryButton>
        </div>
      </form>
    </div>
  );
}

function TextInputWithTooltipWhenDisabled(props: TextInputProps & { disabledTooltip: string }) {
  let { disabledTooltip: tooltip, ...inputProps } = props;

  if (inputProps.disabled) {
    return <Tooltip content={tooltip}>
      <TextInput {...inputProps} />
    </Tooltip>
  } else {
    return <TextInput {...inputProps} />
  }
}
