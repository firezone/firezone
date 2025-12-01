defmodule Domain.Actor do
  use Domain, :schema

  schema "actors" do
    field :type, Ecto.Enum,
      values: [:account_user, :account_admin_user, :service_account, :api_client]

    field :email, :string
    field :password_hash, :string, redact: true

    field :name, :string

    has_many :identities, Domain.ExternalIdentity

    has_many :clients, Domain.Client, preload_order: [desc: :last_seen_at]

    has_many :tokens, Domain.Token

    has_many :memberships, Domain.Membership, on_replace: :delete
    has_many :groups, through: [:memberships, :group]

    belongs_to :account, Domain.Account

    field :last_seen_at, :utc_datetime_usec, virtual: true
    field :identity_count, :integer, virtual: true
    field :disabled_at, :utc_datetime_usec

    belongs_to :directory, Domain.Directory, foreign_key: :created_by_directory_id

    timestamps()
  end

  def changeset(changeset) do
    import Domain.Repo.Changeset

    changeset
    |> validate_required(~w[name type]a)
    |> trim_change(~w[name email]a)
    |> validate_length(:name, max: 512)
    |> normalize_email(:email)
    |> validate_email(:email)
    |> assoc_constraint(:account)
    |> unique_constraint(:email, name: :actors_account_id_email_index)
    |> check_constraint(:type, name: :type_is_valid)
  end

  defp normalize_email(changeset, field) do
    import Domain.Repo.Changeset, only: [try_encode_domain: 1]

    update_change(changeset, field, fn
      nil ->
        nil

      email when is_binary(email) ->
        case String.split(email, "@", parts: 2) do
          [local, domain] ->
            # 1. Trim and downcase domain
            local = String.trim(local)
            domain = String.trim(domain) |> String.downcase()

            # 2. Convert internationalized domains to punycode
            case try_encode_domain(domain) do
              {:ok, punycode_domain} ->
                local <> "@" <> to_string(punycode_domain)

              _error ->
                add_error(changeset, field, "has an invalid domain")
                email
            end

          # No @ sign, return as-is (will be caught by validate_email)
          _ ->
            email
        end

      other ->
        other
    end)
  end
end
