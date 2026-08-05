defmodule Portal.FirezoneSupport.AuthProvider do
  use Ecto.Schema
  import Ecto.Changeset
  import Portal.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  @access_window_secs 86_400

  @portal_session_lifetime_secs 28_800
  @client_session_lifetime_secs 604_800

  schema "firezone_support_auth_providers" do
    # Allows setting the ID manually in changesets
    field :id, :binary_id, primary_key: true

    belongs_to :account, Portal.Account

    belongs_to :auth_provider, Portal.AuthProvider,
      foreign_key: :id,
      define_field: false

    field :expires_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required(~w[expires_at]a)
    |> validate_datetime(:expires_at, greater_than: DateTime.utc_now())
    |> assoc_constraint(:account)
    |> assoc_constraint(:auth_provider)
    |> unique_constraint(:account_id,
      name: :firezone_support_auth_providers_account_id_index,
      message: "Support access is already active for this account."
    )
  end

  def cap_expires_at(%__MODULE__{expires_at: cap}, %DateTime{} = proposed) do
    if DateTime.after?(proposed, cap) do
      cap
    else
      proposed
    end
  end

  def access_window_secs, do: @access_window_secs
  def portal_session_lifetime_secs, do: @portal_session_lifetime_secs
  def client_session_lifetime_secs, do: @client_session_lifetime_secs
end
