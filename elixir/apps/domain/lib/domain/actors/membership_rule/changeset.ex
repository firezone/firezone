defmodule Domain.Actors.MembershipRule.Changeset do
  use Domain, :changeset
  alias Domain.Actors.MembershipRule

  @fields ~w[operator path values]a

  def changeset(membership_rule \\ %MembershipRule{}, attrs) do
    membership_rule
    |> cast(attrs, @fields)
    |> validate_rule()
  end

  defp validate_rule(changeset) do
    case fetch_field(changeset, :operator) do
      {_data_or_changes, true} ->
        changeset
        |> validate_required(~w[operator]a)
        |> delete_change(:path)
        |> delete_change(:values)

      {_data_or_changes, operator} when operator in [:contains, :does_not_contain] ->
        changeset
        |> validate_required(@fields)
        |> validate_path()
        |> validate_length(:values, min: 1, max: 1)

      _other ->
        changeset
        |> validate_required(@fields)
        |> validate_path()
        |> validate_length(:values, min: 1, max: 32)
    end
  end

  defp validate_path(changeset) do
    validate_change(changeset, :path, fn
      :path, [head | _tail] when head in ["claims", "userinfo"] ->
        []

      :path, _path ->
        ["only `claims` or `userinfo` fields are currently supported"]
    end)
  end
end
