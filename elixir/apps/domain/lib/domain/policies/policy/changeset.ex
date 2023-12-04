defmodule Domain.Policies.Policy.Changeset do
  use Domain, :changeset
  alias Domain.Auth
  alias Domain.Policies.Policy

  @fields ~w[description actor_group_id resource_id]a
  @update_fields ~w[description]a
  @required_fields ~w[actor_group_id resource_id]a

  def create(attrs, %Auth.Subject{} = subject) do
    %Policy{}
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> changeset()
    |> put_change(:account_id, subject.account.id)
    |> put_change(:created_by, :identity)
    |> put_change(:created_by_identity_id, subject.identity.id)
  end

  def update(%Policy{} = policy, attrs) do
    policy
    |> cast(attrs, @update_fields)
    |> validate_required(@required_fields)
    |> changeset()
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

  def delete(%Policy{} = policy) do
    policy
    |> change()
    |> put_change(:deleted_at, DateTime.utc_now())
  end

  defp changeset(changeset) do
    changeset
    |> validate_length(:description, min: 1, max: 1024)
    |> unique_constraint(
      :base,
      name: :policies_account_id_resource_id_actor_group_id_index,
      message: "Policy with Group and Resource already exists"
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
