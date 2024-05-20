defmodule Domain.Analytics do
  def get_mixpanel_token do
    config!()
    |> Keyword.get(:mixpanel_token)
  end

  def get_hubspot_workspace_id do
    config!()
    |> Keyword.get(:hubspot_workspace_id)
  end

  defp config! do
    Application.fetch_env!(:domain, __MODULE__)
  end
end
