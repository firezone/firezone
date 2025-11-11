import React, { useEffect, useId, useState } from "react";
import { Button, Label } from "flowbite-react";
import { ManagedTextInput } from "./ManagedInput";
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
    <div className="container p-4">
      <p className="text-neutral-900 mb-6">
        <strong>WARNING</strong>: These settings are intended for internal debug
        purposes <strong>only</strong>. Changing these is not supported and will
        disrupt access to your resources.
      </p>

      <form
        onSubmit={(e) => {
          e.preventDefault();
          saveSettings(localSettings);
        }}
        className="max-w flex flex-col gap-2"
      >
        <div>
          <Label className="text-neutral-600" htmlFor={authBaseUrlId}>
            Auth Base URL
          </Label>
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
          <Label className="text-neutral-600" htmlFor={apiUrlId}>
            API URL
          </Label>
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
          <Label className="text-neutral-600" htmlFor={logFilterInput}>
            Log Filter
          </Label>
          <ManagedTextInput
            name="log_filter"
            id={logFilterInput}
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
          <Button type="reset" onClick={resetSettings} color="alternative">
            Reset to Defaults
          </Button>
          <Button type="submit">Apply</Button>
        </div>
      </form>
    </div>
  );
}
