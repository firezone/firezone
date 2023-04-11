defmodule Domain.Gateways.Group.Changeset do
  use Domain, :changeset
  alias Domain.Gateways

  @fields ~w[name_prefix tags]a

  def changeset(%Gateways.Group{} = group \\ %Gateways.Group{}, attrs) do
    group
    |> cast(attrs, @fields)
    |> trim_change(:name_prefix)
    |> put_default_value(:name_prefix, &Domain.Gateways.generate_name/0)
    |> validate_length(:name_prefix, min: 1, max: 64)
    |> validate_length(:tags, min: 0, max: 128)
    |> validate_no_duplicates(:tags)
    |> validate_list_elements(:tags, fn key, value ->
      if String.length(value) > 64 do
        [{key, "should be at most 64 characters long"}]
      else
        []
      end
    end)
    |> validate_required(@fields)
    |> unique_constraint([:name_prefix])
    |> cast_assoc(:tokens,
      with: fn _token, _attrs ->
        Domain.Gateways.Token.Changeset.create_changeset()
      end,
      required: true
    )
  end

  def delete_changeset(%Gateways.Group{} = group) do
    group
    |> change()
    |> put_change(:deleted_at, DateTime.utc_now())
  end
end
