defmodule Domain.Policies.Policy.Changeset do
  use Domain, :changeset
  alias Domain.Auth
  alias Domain.Policies.Policy

  @fields ~w[description actor_group_id resource_id]a
  @update_fields ~w[description actor_group_id resource_id]a
  @replace_fields ~w[actor_group_id resource_id conditions]a
  @required_fields ~w[actor_group_id resource_id]a

  def create(attrs, %Auth.Subject{} = subject) do
    %Policy{}
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> cast_embed(:conditions, with: &Domain.Policies.Condition.Changeset.changeset/3)
    |> changeset()
    |> put_change(:account_id, subject.account.id)
    |> put_subject_trail(:created_by, subject)
    |> put_change(:persistent_id, Ecto.UUID.generate())
  end

  def update_or_replace(%Policy{} = policy, attrs, %Auth.Subject{} = subject) do
    policy
    |> cast(attrs, @update_fields)
    |> validate_required(@required_fields)
    |> cast_embed(:conditions, with: &Domain.Policies.Condition.Changeset.changeset/3)
    |> changeset()
    |> maybe_replace(policy, subject)
  end

  defp maybe_replace(%{valid?: false} = changeset, _policy, _subject),
    do: {changeset, nil}

  defp maybe_replace(changeset, policy, subject) do
    if any_field_changed?(changeset, @replace_fields) do
      new_changeset =
        changeset
        |> apply_changes()
        |> Map.from_struct()
        |> Map.update(:conditions, [], fn conditions ->
          Enum.map(conditions, &Map.from_struct/1)
        end)
        |> create(subject)
        |> put_change(:persistent_id, policy.persistent_id)

      changeset =
        policy
        |> change(deleted_at: DateTime.utc_now())

      {changeset, new_changeset}
    else
      {changeset, nil}
    end
  end

  def disable(%Policy{} = policy, %Auth.Subject{}) do
    policy
    |> change()
    |> put_default_value(:disabled_at, DateTime.utc_now())
  end

  def enable(%Policy{} = policy) do
    policy
    |> change()
    |> put_change(:disabled_at, nil)
  end

  defp changeset(changeset) do
    changeset
    |> validate_length(:description, min: 1, max: 1024)
    |> unique_constraint(
      :base,
      name: :policies_account_id_resource_id_actor_group_id_index,
      message: "Policy for the selected Group and Resource already exists"
    )
    |> assoc_constraint(:resource)
    |> assoc_constraint(:actor_group)
    |> unique_constraint(
      :base,
      name: :policies_actor_group_id_fkey,
      message: "Not allowed to create policies for groups outside of your account"
    )
    |> unique_constraint(
      :base,
      name: :policies_resource_id_fkey,
      message: "Not allowed to create policies for resources outside of your account"
    )
  end
end
