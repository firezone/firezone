defmodule Domain.Resources.Connection.Changeset do
  use Domain, :changeset
  alias Domain.Auth

  @fields ~w[site_id]a
  @required_fields @fields

  def changeset(account_id, connection, attrs, %Auth.Subject{} = _subject) do
    base_changeset(account_id, connection, attrs)
  end

  def changeset(account_id, connection, attrs) do
    base_changeset(account_id, connection, attrs)
  end

  defp base_changeset(account_id, connection, attrs) do
    connection
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> assoc_constraint(:resource)
    |> assoc_constraint(:site)
    |> assoc_constraint(:account)
    |> check_constraint(:resource,
      name: :internet_resource_in_internet_site,
      message: "type must be 'internet' for the Internet site"
    )
    |> put_change(:account_id, account_id)
  end
end
