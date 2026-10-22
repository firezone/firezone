import React, { useEffect, useId, useState } from "react";
import { AdvancedSettingsViewModel } from "../generated/bindings";
import Button from "./Button";
import { ManagedTextInput } from "./ManagedInput";
import RemixIcon from "./RemixIcon";

interface Props {
  settings: AdvancedSettingsViewModel | null;
  saveSettings: (settings: AdvancedSettingsViewModel) => void;
  resetSettings: () => void;
}

const defaultSettings: AdvancedSettingsViewModel = {
  api_url: "",
  api_url_is_managed: false,
  auth_url: "",
  auth_url_is_managed: false,
  log_filter: "",
  log_filter_is_managed: false,
};

export default function AdvancedSettingsPage({
  settings,
  saveSettings,
  resetSettings,
}: Props) {
  const [localSettings, setLocalSettings] = useState<AdvancedSettingsViewModel>(
    settings ?? defaultSettings
  );

  useEffect(() => {
    setLocalSettings(settings ?? defaultSettings);
  }, [settings]);

  const authBaseUrlId = useId();
  const apiUrlId = useId();
  const logFilterInputId = useId();

  return (
    <div className="page">
      <div className="mb-4 flex max-w-xl gap-2.5 rounded border border-warning/30 bg-warning-light p-3 text-sm text-warning">
        <RemixIcon className="mt-0.5 h-4 w-4" name="alert" />
        <p>
          <strong>WARNING</strong>: These settings are intended for internal
          debug purposes <strong>only</strong>. Changing these is not supported
          and will disrupt access to your resources.
        </p>
      </div>

      <form
        className="max-w-xl space-y-3"
        onSubmit={(event) => {
          event.preventDefault();
          saveSettings(localSettings);
        }}
      >
        <div>
          <label className="form-label" htmlFor={authBaseUrlId}>
            Auth Base URL
          </label>
          <ManagedTextInput
            id={authBaseUrlId}
            managed={localSettings.auth_url_is_managed}
            name="auth_base_url"
            onChange={(event) =>
              setLocalSettings({
                ...localSettings,
                auth_url: event.target.value,
              })
            }
            required
            value={localSettings.auth_url}
          />
        </div>

        <div>
          <label className="form-label" htmlFor={apiUrlId}>
            API URL
          </label>
          <ManagedTextInput
            id={apiUrlId}
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
        </div>

        <div>
          <label className="form-label" htmlFor={logFilterInputId}>
            Log Filter
          </label>
          <ManagedTextInput
            className="font-mono text-xs"
            id={logFilterInputId}
            managed={localSettings.log_filter_is_managed}
            name="log_filter"
            onChange={(event) =>
              setLocalSettings({
                ...localSettings,
                log_filter: event.target.value,
              })
            }
            required
            value={localSettings.log_filter}
          />
        </div>

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
