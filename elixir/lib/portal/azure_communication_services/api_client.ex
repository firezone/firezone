defmodule Portal.AzureCommunicationServices.APIClient do
  @moduledoc """
  Small client for ACS email delivery tracking.
  """

  alias Swoosh.Adapters.AzureCommunicationServices

  def secondary_enabled? do
    secondary_config()[:adapter] == AzureCommunicationServices
  end

  def put_secondary_client_options(%Swoosh.Email{} = email) do
    req_opts = req_opts()

    if req_opts == [] do
      email
    else
      Swoosh.Email.put_private(email, :client_options, req_opts)
    end
  end

  defp secondary_config do
    Portal.Config.fetch_env!(:portal, Portal.Mailer.Secondary)
  end

  defp primary_config do
    Portal.Config.fetch_env!(:portal, Portal.Mailer)
  end

  defp config! do
    tracking_config =
      cond do
        secondary_config()[:adapter] == AzureCommunicationServices ->
          secondary_config()

        primary_config()[:adapter] == AzureCommunicationServices ->
          primary_config()

        true ->
          raise ArgumentError,
                "expected either Portal.Mailer or Portal.Mailer.Secondary to use the ACS adapter"
      end

    Keyword.merge(tracking_config, Portal.Config.get_env(:portal, __MODULE__, []))
  end

  defp req_opts do
    config!()[:req_opts] || []
  end
end
