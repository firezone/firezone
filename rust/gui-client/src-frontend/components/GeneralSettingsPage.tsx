import React, { useEffect, useId, useState } from "react";
import { Button, Label, ToggleSwitch } from "flowbite-react";
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
    <div className="container p-4">
      <form
        onSubmit={(e) => {
          e.preventDefault();
          saveSettings(localSettings);
        }}
        className="max-w flex flex-col gap-2"
      >
        <div>
          <Label className="text-neutral-600" htmlFor={accountSlugInputId}>
            Account slug
          </Label>
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

        <div className="flex flex-col max-w-1/2 gap-4 mt-4">
          <div className="flex justify-between items-center">
            <Label className="text-neutral-600" htmlFor={startMinimizedInputId}>
              Start minimized
            </Label>
            <ToggleSwitch
              name="start_minimized"
              id={startMinimizedInputId}
              checked={localSettings.start_minimized}
              onChange={(e) =>
                setLocalSettings({
                  ...localSettings,
                  start_minimized: e,
                })
              }
            />
          </div>

          <div className="flex justify-between items-center">
            <Label className="text-neutral-600" htmlFor={startOnLoginInputId}>
              Start on login
            </Label>
            <ToggleSwitch
              name="start_on_login"
              id={startOnLoginInputId}
              checked={localSettings.start_on_login}
              onChange={(e) =>
                setLocalSettings({
                  ...localSettings,
                  start_on_login: e,
                })
              }
            />
          </div>

          <div className="flex justify-between items-center">
            <Label className="text-neutral-600" htmlFor={connectOnStartInputId}>
              Connect on start
            </Label>
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
          </div>
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
