defmodule Domain.Auth.Provider.Changeset do
  use Domain, :changeset
  alias Domain.Accounts
  alias Domain.Auth.Provider

  @fields ~w[name adapter adapter_config]a
  @required_fields @fields

  def create_changeset(%Accounts.Account{} = account, attrs) do
    %Provider{}
    |> cast(attrs, @fields)
    |> put_change(:account_id, account.id)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_required(@required_fields)

    # TODO: validate adapter_config using behaviour callback
  end

  def disable_provider(%Provider{} = provider) do
    provider
    |> change()
    |> put_default_value(:disabled_at, DateTime.utc_now())
  end

  def enable_provider(%Provider{} = provider) do
    provider
    |> change()
    |> put_default_value(:disabled_at, nil)
  end

  def delete_provider(%Provider{} = provider) do
    provider
    |> change()
    |> put_default_value(:deleted_at, DateTime.utc_now())
  end
end
