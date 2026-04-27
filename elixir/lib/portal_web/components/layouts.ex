defmodule PortalWeb.Layouts do
  use PortalWeb, :html

  embed_templates "layouts/*"

  # Returns {wrapper_classes, text_class, icon_class, icon_name} for banner color variants.
  # All class strings are static so Tailwind includes them in the build.
  defp banner_classes(:info),
    do:
      {"bg-sky-50 border-sky-200 dark:bg-sky-900/30 dark:border-sky-700", "text-sky-900 dark:text-sky-200",
       "text-sky-500 dark:text-sky-400", "ri-information-line"}

  defp banner_classes(:error),
    do:
      {"bg-red-50 border-red-200 dark:bg-red-900/30 dark:border-red-700", "text-red-900 dark:text-red-200",
       "text-red-500 dark:text-red-400", "ri-error-warning-line"}

  defp banner_classes(:success),
    do:
      {"bg-green-50 border-green-200 dark:bg-green-900/30 dark:border-green-700",
       "text-green-900 dark:text-green-200", "text-green-500 dark:text-green-400",
       "ri-checkbox-circle-line"}

  defp banner_classes(:announcement),
    do:
      {"bg-primary-100 border-primary-200 dark:bg-primary-900/30 dark:border-primary-700",
       "text-primary-900 dark:text-primary-200", "text-primary-600 dark:text-primary-400",
       "ri-megaphone-line"}

  defp banner_classes(_),
    do:
      {"bg-amber-50 border-amber-200 dark:bg-amber-900/30 dark:border-amber-700",
       "text-amber-900 dark:text-amber-200", "text-amber-500 dark:text-amber-400",
       "ri-alert-line"}
end
