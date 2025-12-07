defmodule API.OktaDirectoryJSON do
  alias Domain.Okta

  def index(%{directories: directories}) do
    %{data: Enum.map(directories, &data/1)}
  end

  def show(%{directory: directory}) do
    %{data: data(directory)}
  end

  defp data(%Okta.Directory{} = directory) do
    %{
      id: directory.id,
      account_id: directory.account_id,
      name: directory.name,
      client_id: directory.client_id,
      kid: directory.kid,
      okta_domain: directory.okta_domain,
      error_email_count: directory.error_email_count,
      is_disabled: directory.is_disabled,
      disabled_reason: directory.disabled_reason,
      synced_at: directory.synced_at,
      error_message: directory.error_message,
      errored_at: directory.errored_at,
      inserted_at: directory.inserted_at,
      updated_at: directory.updated_at
    }
  end
end
