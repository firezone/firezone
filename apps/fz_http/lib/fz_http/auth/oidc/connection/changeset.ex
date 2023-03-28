defmodule FzHttp.Auth.OIDC.Connection.Changeset do
  use FzHttp, :changeset

  @fields ~w[provider refresh_token refreshed_at refresh_response]a
  @required_fields ~w[provider refresh_token]a

  def changeset(connection, attrs) do
    connection
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
  end
end
