defmodule PortalWeb.Layouts do
  use PortalWeb, :html

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def fetch_banner do
      from(b in Portal.Banner)
      |> Safe.unscoped()
      |> Safe.one()
    end
  end

  embed_templates "layouts/*"

  # Returns {wrapper_classes, text_class, icon_class, icon_name} for banner color variants.
  # All class strings are static so Tailwind includes them in the build.
  defp banner_classes(:info),
    do: {"bg-info-light border-info/30", "text-info", "text-info", "ri-information-line"}

  defp banner_classes(:error),
    do: {"bg-danger-light border-danger/30", "text-danger", "text-danger", "ri-error-warning-line"}

  defp banner_classes(:success),
    do: {"bg-success-light border-success/30", "text-success", "text-success", "ri-checkbox-circle-line"}

  # NOTE: kept on the hand-paired heat-wave palette. The brand tint tokens are the wrong
  # strengths for a banner
  defp banner_classes(:announcement),
    do:
      {"bg-primary-100 border-primary-200 dark:bg-primary-900/30 dark:border-primary-700",
       "text-primary-900 dark:text-primary-200", "text-primary-600 dark:text-primary-400",
       "ri-megaphone-line"}

  defp banner_classes(_),
    do: {"bg-warning-light border-warning/30", "text-warning", "text-warning", "ri-alert-line"}
end
