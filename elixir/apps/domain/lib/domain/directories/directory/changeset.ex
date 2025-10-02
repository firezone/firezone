defmodule Domain.Directories.Directory.Changeset do
  use Domain, :changeset

  alias Domain.{
    Auth,
    Directories.Directory
  }

  @required_fields ~w[account_id type created_by created_by_subject]a

  def create(attrs, %Auth.Subject{} = subject) do
    %Directory{}
    |> cast(attrs, @required_fields)
    |> put_change(:account_id, subject.account.id)
    |> put_subject_trail(:created_by, subject)
    |> changeset()
  end

  def changeset(changeset) do
    changeset
    |> validate_required(@required_fields)
    |> assoc_constraint(:account)
    |> unique_constraint([:account_id, :type],
      name: :directories_account_id_type_index,
      message: "is already configured for this account and directory type"
    )
  end
end
