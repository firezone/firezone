defmodule Portal.Actor do
  use Ecto.Schema
  import Ecto.Changeset
  import Portal.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "actors" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    field :type, Ecto.Enum,
      values: [:account_user, :account_admin_user, :service_account, :api_client]

    field :email, :string
    field :password_hash, :string, redact: true
    field :allow_email_otp_sign_in, :boolean, default: false

    field :name, :string

    has_many :identities, Portal.ExternalIdentity, references: :id

    has_many :clients, Portal.Device,
      where: [type: :client],
      preload_order: [desc: :inserted_at],
      references: :id

    has_many :client_tokens, Portal.ClientToken, references: :id
    has_many :one_time_passcodes, Portal.OneTimePasscode, references: :id
    has_many :memberships, Portal.Membership, on_replace: :delete, references: :id
    has_many :groups, through: [:memberships, :group]

    embeds_one :preferences, Portal.Actor.Preferences, on_replace: :update

    field :last_seen_at, :utc_datetime_usec, virtual: true
    field :identity_count, :integer, virtual: true
    field :disabled_at, :utc_datetime_usec

    belongs_to :directory, Portal.Directory, foreign_key: :created_by_directory_id

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required(~w[name type]a)
    |> trim_change(~w[name email]a)
    |> validate_length(:name, max: 255)
    |> validate_type_transition()
    |> normalize_email(:email)
    |> validate_email(:email)
    |> assoc_constraint(:account)
    |> assoc_constraint(:directory, name: :actors_created_by_directory_id_fkey)
    |> unique_constraint(:email, name: :actors_account_id_email_index)
    |> check_constraint(:type, name: :type_is_valid)
  end

  defp validate_type_transition(changeset) do
    old_type = changeset.data.type
    new_type = get_change(changeset, :type)

    cond do
      is_nil(new_type) ->
        changeset

      is_nil(old_type) ->
        changeset

      old_type == :api_client ->
        add_error(changeset, :type, "cannot change the type of an API client")

      old_type == :service_account ->
        add_error(changeset, :type, "cannot change the type of a service account")

      old_type in [:account_user, :account_admin_user] and
          new_type in [:api_client, :service_account] ->
        add_error(changeset, :type, "cannot change a user to a service account or API client")

      true ->
        changeset
    end
  end

  defp normalize_email(changeset, field) do
    update_change(changeset, field, fn
      nil ->
        nil

      email when is_binary(email) ->
        case encode_email(email) do
          {:ok, encoded} ->
            encoded

          :error ->
            add_error(changeset, field, "has an invalid domain")
            email
        end

      other ->
        other
    end)
  end

  defp encode_email(email) do
    case String.split(email, "@", parts: 2) do
      [local, domain] ->
        local = String.trim(local)
        domain = String.trim(domain) |> String.downcase()

        case try_encode_domain(domain) do
          {:ok, punycode_domain} -> {:ok, local <> "@" <> to_string(punycode_domain)}
          _error -> :error
        end

      # No @ sign, return as-is (will be caught by validate_email)
      _ ->
        {:ok, email}
    end
  end
end
