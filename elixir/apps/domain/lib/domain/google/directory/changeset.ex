defmodule Domain.Google.Directory.Changeset do
  use Domain, :changeset

  alias Domain.{
    Accounts,
    Auth,
    Google.Directory
  }

  @required_fields ~w[account_id directory_id hosted_domain created_by created_by_subject]a

  def create(attrs, %Accounts.Account{} = account) do
    %Directory{}
    |> cast(attrs, @required_fields)
    |> put_change(:account_id, account.id)
    |> put_subject_trail(:created_by, :system)
    |> changeset()
  end

  def create(attrs, %Auth.Subject{} = subject) do
    %Directory{}
    |> cast(attrs, @required_fields)
    |> put_change(:account_id, subject.account.id)
    |> put_subject_trail(:created_by, subject)
    |> changeset()
  end

  def update(%Directory{} = directory, attrs) do
    directory
    |> cast(
      attrs,
      ~w[hosted_domain error_count disabled_at disabled_reason synced_at error error_emailed_at]a
    )
    |> changeset()
  end

  def changeset(changeset) do
    changeset
    |> validate_required(@required_fields)
    |> validate_length(:hosted_domain, min: 1, max: 255)
    |> validate_number(:error_count, greater_than_or_equal_to: 0)
    |> validate_length(:error, max: 2_000)
    |> assoc_constraint(:account)
    |> assoc_constraint(:directory)
    |> unique_constraint([:account_id, :hosted_domain],
      message: "is already configured for this account and Google Workspace domain"
    )
  end
end
