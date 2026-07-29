import React, { useEffect, useId, useState } from "react";
import Button from "./Button";
import { ManagedTextInput } from "./ManagedInput";
import RemixIcon from "./RemixIcon";
import { AdvancedSettingsViewModel } from "../generated/bindings";

interface Props {
  settings: AdvancedSettingsViewModel | null;
  saveSettings: (settings: AdvancedSettingsViewModel) => void;
  resetSettings: () => void;
}

export default function AdvancedSettingsPage({
  settings,
  saveSettings,
  resetSettings,
}: Props) {
  // Local settings can be edited without affecting the global state.
  const [localSettings, setLocalSettings] = useState<AdvancedSettingsViewModel>(
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

  const authBaseUrlId = useId();
  const apiUrlId = useId();
  const logFilterInput = useId();

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
        onSubmit={(e) => {
          e.preventDefault();
          saveSettings(localSettings);
        }}
        className="max-w-xl space-y-3"
      >
        <div>
          <label className="form-label" htmlFor={authBaseUrlId}>
            Auth Base URL
          </label>
          <ManagedTextInput
            name="auth_base_url"
            id={authBaseUrlId}
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
          <label className="form-label" htmlFor={apiUrlId}>
            API URL
          </label>
          <ManagedTextInput
            name="api_url"
            id={apiUrlId}
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
          <label className="form-label" htmlFor={logFilterInput}>
            Log Filter
          </label>
          <ManagedTextInput
            name="log_filter"
            id={logFilterInput}
            managed={localSettings.log_filter_is_managed}
            value={localSettings.log_filter}
            className="font-mono text-xs"
            onChange={(e) =>
              setLocalSettings({
                ...localSettings,
                log_filter: e.target.value,
              })
            }
            required
          />
        </div>

        <div className="flex justify-end gap-2 border-t border-border pt-3">
          <Button type="reset" onClick={resetSettings}>
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
