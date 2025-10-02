defmodule Domain.Firezone.Directory.Changeset do
  use Domain, :changeset

  alias Domain.{
    Accounts,
    Auth,
    Firezone.Directory
  }

  @required_fields ~w[account_id created_by created_by_subject]a

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
      ~w[jit_provisioning]a
    )
    |> changeset()
  end

  def changeset(changeset) do
    changeset
    |> validate_required(@required_fields)
    |> assoc_constraint(:account)
    |> assoc_constraint(:directory)
    |> unique_constraint([:account_id],
      message: "is already configured for this account"
    )
  end

  defp maybe_create_parent_directory(changeset, account_id) do
    case {get_field(changeset, :directory_id), get_assoc(changeset, :directory)} do
      {nil, nil} ->
        changeset
        |> put_assoc(:directory, %Domain.Directories.Directory{
          account_id: account_id,
          type: :firezone
        })

      _directory_id ->
        changeset
    end
  end
end
