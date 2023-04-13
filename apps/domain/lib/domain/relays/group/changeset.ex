defmodule Domain.Relays.Group.Changeset do
  use Domain, :changeset
  alias Domain.Relays

  @fields ~w[name]a

  def changeset(%Relays.Group{} = group \\ %Relays.Group{}, attrs) do
    group
    |> cast(attrs, @fields)
    |> trim_change(:name)
    |> put_default_value(:name, &Domain.NameGenerator.generate/0)
    |> validate_length(:name, min: 1, max: 64)
    |> validate_required(@fields)
    |> unique_constraint([:name])
    |> cast_assoc(:tokens,
      with: fn _token, _attrs ->
        Domain.Relays.Token.Changeset.create_changeset()
      end,
      required: true
    )
  end

  def delete_changeset(%Relays.Group{} = group) do
    group
    |> change()
    |> put_default_value(:deleted_at, DateTime.utc_now())
  end
end
