defmodule Domain.Resources.Connection.Changeset do
  use Domain, :changeset
  alias Domain.Resources.Connection

  @fields ~w[gateway_id]a
  @required_fields @fields

  def changeset(account_id, connection, attrs) do
    connection
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> assoc_constraint(:resource)
    |> assoc_constraint(:gateway)
    |> assoc_constraint(:account)
    |> put_change(:account_id, account_id)
  end
end
