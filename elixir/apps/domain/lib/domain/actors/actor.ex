defmodule Domain.Actors.Actor do
  use Domain, :schema

  schema "actors" do
    field :type, Ecto.Enum,
      values: [:account_user, :account_admin_user, :service_account, :api_client]

    field :email, :string

    # TODO: IdP refactor
    # Move this to auth_identities
    field :name, :string

    has_many :identities, Domain.Auth.Identity

    has_many :clients, Domain.Clients.Client, preload_order: [desc: :last_seen_at]

    has_many :tokens, Domain.Tokens.Token

    has_many :memberships, Domain.Actors.Membership, on_replace: :delete
    has_many :groups, through: [:memberships, :group]

    belongs_to :account, Domain.Accounts.Account

    field :last_seen_at, :utc_datetime_usec, virtual: true
    field :disabled_at, :utc_datetime_usec

    # Intentionally not a foreign key because it can point to different directory tables
    field :created_by_directory_id, :binary_id

    subject_trail(~w[actor identity provider system]a)
    timestamps()
  end

  def changeset(changeset) do
    changeset
    |> validate_required(~w[name type]a)
    |> trim_change(~w[name email]a)
    |> maybe_populate_email_from_name()
    |> validate_length(:name, max: 512)
    |> normalize_email(:email)
    |> validate_email(:email)
    |> assoc_constraint(:account)
    |> unique_constraint(:email, name: :actors_account_id_email_index)
  end

  defp maybe_populate_email_from_name(changeset) do
    type = get_field(changeset, :type)
    email = get_field(changeset, :email)
    name = get_field(changeset, :name)

    if type == :service_account and (is_nil(email) or email == "") and not is_nil(name) do
      normalized_name =
        name
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9]+/, "-")
        |> String.trim("-")

      put_change(changeset, :email, "#{normalized_name}@service-account.local")
    else
      changeset
    end
  end
end
