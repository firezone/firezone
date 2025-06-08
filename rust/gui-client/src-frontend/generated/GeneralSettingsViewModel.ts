export interface GeneralSettingsViewModel {
    start_minimized: boolean;
    start_on_login: boolean;
    connect_on_start: boolean;
    connect_on_start_is_managed: boolean;
    account_slug: string;
    account_slug_is_managed: boolean;
}
export const GENERAL_SETTINGS_CHANGED = "general_settings_changed";
export const ADVANCED_SETTINGS_CHANGED = "advanced_settings_changed";
