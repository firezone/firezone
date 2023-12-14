defmodule Domain.Instrumentation do
  alias Domain.Clients
  alias Domain.GoogleCloudPlatform

  def create_remote_log_sink(%Clients.Client{} = client, actor_name, account_slug) do
    config = config!()
    enabled? = Keyword.fetch!(config, :client_logs_enabled)

    if enabled? and GoogleCloudPlatform.enabled?() do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      bucket =
        Application.fetch_env!(:domain, __MODULE__)
        |> Keyword.fetch!(:client_logs_bucket)

      filename =
        "clients/#{account_slug}/#{actor_name}/#{client.id}/#{now}-#{System.unique_integer([:positive])}.json"

      GoogleCloudPlatform.sign_url(bucket, filename, verb: "PUT")
    else
      {:error, :disabled}
    end
  end

  defp config! do
    Domain.Config.fetch_env!(:domain, __MODULE__)
  end
end
