defmodule Portal.FirezoneSupport.AuthProvider do
  use Ecto.Schema
  import Ecto.Changeset
  import Portal.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  @access_window_secs 86_400

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

  def access_window_secs, do: @access_window_secs
end
