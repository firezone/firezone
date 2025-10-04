defmodule Domain.Entra.Directory.Changeset do
  use Domain, :changeset

  alias Domain.{
    Accounts,
    Auth,
    Entra.Directory
  }

  @required_fields ~w[name account_id tenant_id created_by created_by_subject]a

  def create(attrs, %Accounts.Account{} = account) do
    %Directory{}
    |> cast(attrs, @required_fields)
    |> put_change(:account_id, account.id)
    |> put_subject_trail(:created_by, :system)
    |> maybe_create_parent_directory(account.id)
    |> changeset()
  end

  def create(attrs, %Auth.Subject{} = subject) do
    %Directory{}
    |> cast(attrs, @required_fields)
    |> put_change(:account_id, subject.account.id)
    |> put_subject_trail(:created_by, subject)
    |> maybe_create_parent_directory(subject.account.id)
    |> changeset()
  end

  def update(%Directory{} = directory, attrs) do
    directory
    |> cast(
      attrs,
      ~w[jit_provisioning name tenant_id error_count disabled_at disabled_reason synced_at error error_emailed_at]a
    )
    |> changeset()
  end

  def changeset(changeset) do
    changeset
    |> validate_required(@required_fields)
    |> validate_length(:tenant_id, min: 1, max: 255)
    |> validate_number(:error_count, greater_than_or_equal_to: 0)
    |> validate_length(:error, max: 2_000)
    |> assoc_constraint(:account)
    |> assoc_constraint(:directory)
    |> unique_constraint([:account_id, :tenant_id],
      message: "is already configured for this account and Entra Workspace domain"
    )
  end

  defp maybe_create_parent_directory(changeset, account_id) do
    case {get_field(changeset, :directory_id), get_assoc(changeset, :directory)} do
      {nil, nil} ->
        changeset
        |> put_assoc(:directory, %Domain.Directories.Directory{
          account_id: account_id,
          type: :entra
        })

      _ ->
        changeset
    end
  end
end
