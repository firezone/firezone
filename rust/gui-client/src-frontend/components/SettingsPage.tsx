import React, { useEffect, useState } from "react";
import { Button, TextInput, HelperText, Label } from "flowbite-react";
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
      <div className="mb-4 pb-2">
        <h2 className="text-xl font-semibold mb-4">Advanced Settings</h2>
      </div>

      <div className="p-4 rounded-lg">
        <p className="mx-8 text-neutral-900 mb-6">
          <strong>WARNING</strong>: These settings are intended for internal
          debug purposes <strong>only</strong>. Changing these is not supported
          and will disrupt access to your resources.
        </p>

        <form
          onSubmit={() => saveSettings(localSettings)}
          className="max-w-md mt-8 mx-auto"
        >
          <div className="relative z-0 w-full mb-5 group">
            <TextInput
              name="auth_base_url"
              id="auth-base-url-input"
              disabled={localSettings.auth_url_is_managed}
              value={localSettings.auth_url}
              onChange={(e) =>
                setLocalSettings({
                  ...localSettings,
                  auth_url: e.target.value,
                })
              }
              className="block py-2.5 px-0 w-full text-sm text-neutral-900 bg-transparent border-0 border-b-2 border-neutral-300 appearance-none focus:outline-hidden focus:ring-0 focus:border-accent-600 peer"
              placeholder=" "
              required
            />
            <Label htmlFor="auth-base-url-input">Auth Base URL</Label>
          </div>

          <div className="relative z-0 w-full mb-5 group">
            <TextInput
              name="api_url"
              id="api-url-input"
              disabled={localSettings.api_url_is_managed}
              value={localSettings.api_url}
              onChange={(e) =>
                setLocalSettings({
                  ...localSettings,
                  api_url: e.target.value,
                })
              }
              className="block py-2.5 px-0 w-full text-sm text-neutral-900 bg-transparent border-0 border-b-2 border-neutral-300 appearance-none focus:outline-hidden focus:ring-0 focus:border-accent-600 peer"
              placeholder=" "
              required
            />
            <Label htmlFor="api-url-input">API URL</Label>
          </div>

          <div className="relative z-0 w-full mb-5 group">
            <TextInput
              name="log_filter"
              id="log-filter-input"
              disabled={localSettings.log_filter_is_managed}
              value={localSettings.log_filter}
              onChange={(e) =>
                setLocalSettings({
                  ...localSettings,
                  log_filter: e.target.value,
                })
              }
              className="block py-2.5 px-0 w-full text-sm text-neutral-900 bg-transparent border-0 border-b-2 border-neutral-300 appearance-none focus:outline-hidden focus:ring-0 focus:border-accent-600 peer"
              placeholder=" "
              required
            />
            <Label htmlFor="log-filter-input">Log Filter</Label>
          </div>

          <div className="inline-flex w-full justify-between">
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
    </div>
  );
}
