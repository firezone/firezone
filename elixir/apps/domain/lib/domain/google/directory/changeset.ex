defmodule Domain.Google.Directory.Changeset do
  use Domain, :changeset

  alias Domain.{
    Auth,
    Google.Directory
  }

  @required_fields ~w[name hosted_domain issuer]a
  @create_fields @required_fields ++ ~w[superadmin_email impersonation_email]a
  @update_fields ~w[superadmin_email superadmin_emailed_at impersonation_email name
    error_count disabled_at disabled_reason synced_at error error_emailed_at]a

  def create(attrs, %Auth.Subject{} = subject) do
    %Directory{}
    |> cast(attrs, @create_fields)
    |> put_change(:account_id, subject.account.id)
    |> put_subject_trail(:created_by, subject)
    |> changeset()
  end

  def update(%Directory{} = directory, attrs) do
    directory
    |> cast(attrs, @update_fields)
    |> changeset()
  end

  def changeset(changeset) do
    changeset
    |> validate_required(@required_fields)
    |> validate_length(:hosted_domain, min: 1, max: 255)
    |> validate_length(:issuer, min: 1, max: 2_000)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_number(:error_count, greater_than_or_equal_to: 0)
    |> validate_length(:error, max: 2_000)
    |> assoc_constraint(:account)
    |> unique_constraint(:hosted_domain,
      name: :google_directories_account_id_issuer_hosted_domain_index,
      message: "is already configured for this account and Google Workspace domain"
    )
    |> unique_constraint(:name, name: :google_directories_account_id_name_index)
    |> foreign_key_constraint(:account_id, name: :google_directories_account_id_fkey)
  end
end
