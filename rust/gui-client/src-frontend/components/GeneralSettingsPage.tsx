import React, { useEffect, useId, useState } from "react";
import Button from "./Button";
import { ManagedToggleSwitch, ManagedTextInput } from "./ManagedInput";
import { GeneralSettingsViewModel } from "../generated/bindings";

interface Props {
  settings: GeneralSettingsViewModel | null;
  saveSettings: (settings: GeneralSettingsViewModel) => void;
  resetSettings: () => void;
}

export default function GeneralSettingsPage({
  settings,
  saveSettings,
  resetSettings,
}: Props) {
  // Local settings can be edited without affecting the global state.
  const [localSettings, setLocalSettings] = useState<GeneralSettingsViewModel>(
    settings ?? {
      start_minimized: true,
      account_slug: "",
      connect_on_start: false,
      start_on_login: false,
      account_slug_is_managed: false,
      connect_on_start_is_managed: false,
    }
  );

  useEffect(() => {
    setLocalSettings(
      settings ?? {
        start_minimized: true,
        account_slug: "",
        connect_on_start: false,
        start_on_login: false,
        account_slug_is_managed: false,
        connect_on_start_is_managed: false,
      }
    );
  }, [settings]);

  const accountSlugInputId = useId();
  const startMinimizedInputId = useId();
  const startOnLoginInputId = useId();
  const connectOnStartInputId = useId();
  return (
    <div className="page">
      <form
        onSubmit={(e) => {
          e.preventDefault();
          saveSettings(localSettings);
        }}
        className="max-w-xl space-y-5"
      >
        <div>
          <label className="form-label" htmlFor={accountSlugInputId}>
            Account slug
          </label>
          <ManagedTextInput
            name="account_slug"
            id={accountSlugInputId}
            managed={localSettings.account_slug_is_managed}
            value={localSettings.account_slug}
            onChange={(e) =>
              setLocalSettings({
                ...localSettings,
                account_slug: e.target.value,
              })
            }
          />
        </div>

        <div className="panel divide-y divide-border">
          <SettingRow inputId={startMinimizedInputId} label="Start minimized">
            <ManagedToggleSwitch
              name="start_minimized"
              id={startMinimizedInputId}
              managed={false}
              checked={localSettings.start_minimized}
              onChange={(e) =>
                setLocalSettings({
                  ...localSettings,
                  start_minimized: e,
                })
              }
            />
          </SettingRow>

          <SettingRow inputId={startOnLoginInputId} label="Start on login">
            <ManagedToggleSwitch
              name="start_on_login"
              id={startOnLoginInputId}
              managed={false}
              checked={localSettings.start_on_login}
              onChange={(e) =>
                setLocalSettings({
                  ...localSettings,
                  start_on_login: e,
                })
              }
            />
          </SettingRow>

          <SettingRow inputId={connectOnStartInputId} label="Connect on start">
            <ManagedToggleSwitch
              name="connect-on-start"
              id={connectOnStartInputId}
              managed={localSettings.connect_on_start_is_managed}
              checked={localSettings.connect_on_start}
              onChange={(e) =>
                setLocalSettings({
                  ...localSettings,
                  connect_on_start: e,
                })
              }
            />
          </SettingRow>
        </div>

        <div className="flex justify-end gap-2 border-t border-border pt-4">
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

interface SettingRowProps extends React.PropsWithChildren {
  inputId: string;
  label: string;
}

function SettingRow({ children, inputId, label }: SettingRowProps) {
  return (
    <div className="flex items-center justify-between gap-6 px-4 py-3">
      <label
        className="block text-sm font-medium text-heading"
        htmlFor={inputId}
      >
        {label}
      </label>
      {children}
    </div>
  );
}
