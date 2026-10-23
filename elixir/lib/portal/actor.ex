defmodule Portal.Actor do
  use Ecto.Schema
  import Ecto.Changeset
  import Portal.Changeset
  alias Portal.Email

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "actors" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    field :type, Ecto.Enum,
      values: [:account_user, :account_admin_user, :service_account, :api_client]

    # Who owns the actor. The system provisions a few per account, such as the
    # service account behind infrastructure devices; those cannot be changed or
    # deleted by admins.
    field :managed_by, Ecto.Enum, values: ~w[account system]a, default: :account

    field :email, :string
    field :password_hash, :string, redact: true
    field :allow_email_otp_sign_in, :boolean, default: false

    field :name, :string

    has_many :identities, Portal.ExternalIdentity, references: :id
    has_many :pending_identities, Portal.PendingIdentity, references: :id

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
    field :is_disabled, :boolean, default: false, read_after_writes: true

    belongs_to :directory, Portal.Directory, foreign_key: :created_by_directory_id

    # Set only by directory sync, which writes raw SQL. Any other change to
    # is_disabled clears it, see `track_disabling_directory/1`.
    belongs_to :disabling_directory, Portal.Directory, foreign_key: :disabled_by_directory_id

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required(~w[name type]a)
    |> trim_change(~w[name email]a)
    |> validate_length(:name, max: 255)
    |> validate_type_transition()
    |> validate_system_actor_unchanged()
    |> track_disabling_directory()
    |> normalize_email(:email)
    |> validate_email(:email)
    |> assoc_constraint(:account)
    |> assoc_constraint(:directory, name: :actors_created_by_directory_id_fkey)
    |> assoc_constraint(:disabling_directory, name: :actors_disabled_by_directory_id_fkey)
    |> check_constraint(:disabled_by_directory_id, name: :disabled_by_directory_requires_disabled)
    |> unique_constraint(:email, name: :actors_account_id_email_index)
    |> check_constraint(:type, name: :type_is_valid)
    |> check_constraint(:managed_by, name: :actors_managed_by_is_valid)
  end

  @infrastructure_name "Infrastructure"

  @doc """
  Attributes of the service account every account gets at creation: the actor
  infrastructure devices connect with when nobody else is named, owned by the
  system so it cannot be renamed, disabled or deleted. Compare
  `Portal.Group.account_owner_attrs/0`.
  """
  @spec infrastructure_attrs() :: map()
  def infrastructure_attrs do
    %{name: @infrastructure_name, type: :service_account, managed_by: :system}
  end

  @doc "Whether the system owns `actor`, so admins cannot change or delete it."
  @spec system_managed?(t()) :: boolean()
  def system_managed?(%__MODULE__{managed_by: managed_by}), do: managed_by == :system

  def email_meaningfully_changed?(%Ecto.Changeset{} = changeset) do
    case fetch_change(changeset, :email) do
      {:ok, new_email} -> normalize_for_compare(new_email) != normalize_for_compare(changeset.data.email)
      :error -> false
    end
  end

  # A system-managed actor is exactly what the system made it: no rename, no
  # email, no type change, no disabling. Creating one is the only write.
  defp validate_system_actor_unchanged(%Ecto.Changeset{data: %__MODULE__{managed_by: :system}} = changeset)
       when changeset.changes != %{} do
    add_error(changeset, :base, "system-managed actors cannot be changed")
  end

  defp validate_system_actor_unchanged(changeset), do: changeset

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

  # A directory re-enables only the actors it disabled itself, so any disable or
  # enable made outside directory sync takes the decision away from it.
  defp track_disabling_directory(changeset) do
    if changed?(changeset, :is_disabled) and not changed?(changeset, :disabled_by_directory_id) do
      put_change(changeset, :disabled_by_directory_id, nil)
    else
      changeset
    end
  end

  defp normalize_for_compare(nil), do: ""

  defp normalize_for_compare(value) when is_binary(value) do
    case Email.normalize_for_match(value) do
      {:ok, email} -> email
      :error -> value |> String.trim() |> String.downcase()
    end
  end

  defp normalize_email(changeset, field) do
    update_change(changeset, field, fn
      nil ->
        nil

      email when is_binary(email) ->
        case Email.normalize(email) do
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
end
