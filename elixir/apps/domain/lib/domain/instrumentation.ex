defmodule Domain.Instrumentation do
  alias Domain.Accounts
  alias Domain.Actors
  alias Domain.Clients
  alias Domain.GoogleCloudPlatform

  def create_remote_log_sink(%Clients.Client{} = client) do
    config = config!()

    with {:ok, actor} <- Actors.fetch_actor_by_id(client.actor_id),
         {:ok, account} <- Accounts.fetch_account_by_id(actor.account_id),
         true <- Keyword.fetch!(config, :client_logs_enabled),
         true <- GoogleCloudPlatform.enabled?() do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      bucket =
        Application.fetch_env!(:domain, __MODULE__)
        |> Keyword.fetch!(:client_logs_bucket)

      filename =
        "clients/#{account.slug}/#{actor.name}/#{client.id}/#{now}-#{System.unique_integer([:positive])}.json"

      GoogleCloudPlatform.sign_url(bucket, filename, verb: "PUT")
    else
      _ -> {:error, :disabled}
    end
  end

  defp config! do
    Domain.Config.fetch_env!(:domain, __MODULE__)
  end
end
