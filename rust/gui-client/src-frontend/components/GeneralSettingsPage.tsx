import React, { useEffect, useId, useState } from "react";
import { GeneralSettingsViewModel } from "../generated/bindings";
import Button from "./Button";
import { ManagedTextInput, ManagedToggleSwitch } from "./ManagedInput";

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

  const accountSlugInputId = useId();
  const startMinimizedInputId = useId();
  const startOnLoginInputId = useId();
  const connectOnStartInputId = useId();

  return (
    <div className="page">
      <form
        className="max-w-xl space-y-5"
        onSubmit={(event) => {
          event.preventDefault();
          saveSettings(localSettings);
        }}
      >
        <div>
          <label className="form-label" htmlFor={accountSlugInputId}>
            Account slug
          </label>
          <ManagedTextInput
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
        </div>

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

          <SettingRow inputId={connectOnStartInputId} label="Connect on start">
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

        <div className="flex justify-end gap-2 border-t border-border pt-4">
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
