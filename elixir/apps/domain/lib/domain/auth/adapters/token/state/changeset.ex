defmodule Domain.Auth.Adapters.Token.State.Changeset do
  use Domain, :changeset

  @fields ~w[expires_at]a

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_datetime(:expires_at, greater_than: DateTime.utc_now())
  end
end
