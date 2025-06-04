import React, { useEffect, useState } from "react";
import { Button, Label, ToggleSwitch } from "flowbite-react";
import { GeneralSettingsViewModel } from "../generated/GeneralSettingsViewModel";
import { ManagedToggleSwitch, ManagedTextInput } from "./ManagedInput";

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

  return (
    <div className="container p-4">
      <div className="pb-2">
        <h2 className="text-xl font-semibold">General settings</h2>
      </div>

      <form
        onSubmit={(e) => {
          e.preventDefault();
          saveSettings(localSettings);
        }}
        className="max-w flex flex-col gap-2"
      >
        <div>
          <Label className="text-neutral-600" htmlFor="account-slug-input">
            Account slug
          </Label>
          <ManagedTextInput
            name="account_slug"
            id="account-slug-input"
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

        <div className="max-w-1/2">
          <div className="mt-4 flex justify-between items-center">
            <Label className="text-neutral-600" htmlFor="start-minimized-input">
              Start minimized
            </Label>
            <ToggleSwitch
              name="start_minimized"
              id="start-minimized-input"
              checked={localSettings.start_minimized}
              onChange={(e) =>
                setLocalSettings({
                  ...localSettings,
                  start_minimized: e,
                })
              }
            />
          </div>

          <div className="mt-4 flex justify-between items-center">
            <Label className="text-neutral-600" htmlFor="start-on-login-input">
              Start on login
            </Label>
            <ToggleSwitch
              name="start_on_login"
              id="start-on-login-input"
              checked={localSettings.start_on_login}
              onChange={(e) =>
                setLocalSettings({
                  ...localSettings,
                  start_on_login: e,
                })
              }
            />
          </div>

          <div className="mt-4 flex justify-between items-center">
            <Label
              className="text-neutral-600"
              htmlFor="connect-on-start-input"
            >
              Connect on start
            </Label>
            <ManagedToggleSwitch
              name="connect-on-start"
              id="connect-on-start-input"
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
