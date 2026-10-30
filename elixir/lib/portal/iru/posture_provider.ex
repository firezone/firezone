defmodule Portal.Iru.PostureProvider do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @regions ~w[us eu]a

  @type t :: %__MODULE__{}

  schema "iru_posture_providers" do
    belongs_to :account, Portal.Account, primary_key: true

    # Shares its id with the posture_providers row; set both when creating.
    field :id, :binary_id, primary_key: true

    belongs_to :posture_provider, Portal.PostureProvider,
      foreign_key: :id,
      define_field: false

    # Stored on the posture_providers row, which is where the account-wide
    # uniqueness lives; carried here so a form can read and write it.
    field :name, :string, virtual: true, default: "Iru"
    field :subdomain, :string
    field :region, Ecto.Enum, values: @regions, default: :us
    field :api_token, :string, redact: true
    field :is_verified, :boolean, default: false, read_after_writes: true
    field :is_disabled, :boolean, default: false, read_after_writes: true
    field :disabled_reason, :string
    field :synced_at, :utc_datetime_usec
    field :errored_at, :utc_datetime_usec
    field :error_message, :string
    field :error_email_count, :integer, default: 0, read_after_writes: true

    has_many :devices, Portal.Iru.Device,
      foreign_key: :posture_provider_id,
      references: :id

    timestamps()
  end

  def regions, do: @regions

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> update_change(:subdomain, &normalize_subdomain/1)
    |> validate_required([:subdomain, :region, :api_token, :is_verified])
    |> validate_length(:subdomain, min: 1, max: 63)
    |> validate_format(:subdomain, ~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/,
      message: "must be the first label of your Iru API URL, such as \"acme\""
    )
    |> validate_length(:api_token, min: 1, max: 255)
    |> validate_number(:error_email_count, greater_than_or_equal_to: 0)
    |> assoc_constraint(:account)
    |> assoc_constraint(:posture_provider)
    |> unique_constraint(:subdomain,
      name: :iru_posture_providers_account_id_region_subdomain_index,
      message: "This Iru tenant is already connected."
    )
  end

  # Admins paste the whole API URL from Settings > Access as often as they type
  # the first label of it, and Iru only ever gives them a lowercase one.
  defp normalize_subdomain(nil), do: nil

  defp normalize_subdomain(subdomain) do
    subdomain
    |> String.trim()
    |> String.downcase()
    |> String.replace_prefix("https://", "")
    |> String.replace_prefix("http://", "")
    |> String.split(".")
    |> List.first()
  end
end
