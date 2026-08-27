defmodule Portal.Santa.PostureProvider do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "santa_posture_providers" do
    belongs_to :account, Portal.Account, primary_key: true

    # Shares its id with the posture_providers row; set both when creating.
    field :id, :binary_id, primary_key: true

    belongs_to :posture_provider, Portal.PostureProvider,
      foreign_key: :id,
      define_field: false

    field :name, :string, virtual: true, default: "Santa"
    field :api_url, :string
    field :api_key, :string, redact: true
    field :is_verified, :boolean, default: false, read_after_writes: true
    field :is_disabled, :boolean, default: false, read_after_writes: true
    field :disabled_reason, :string
    field :synced_at, :utc_datetime_usec
    field :errored_at, :utc_datetime_usec
    field :error_message, :string
    field :error_email_count, :integer, default: 0, read_after_writes: true

    has_many :devices, Portal.Santa.Device,
      foreign_key: :posture_provider_id,
      references: :id

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> update_change(:api_url, &normalize_api_url/1)
    |> validate_required([:api_url, :api_key, :is_verified])
    |> validate_length(:api_url, min: 1, max: 255)
    |> validate_format(
      :api_url,
      ~r/^https:\/\/(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+workshop\.cloud$/,
      message: "must be a Workshop tenant URL, such as https://acme.workshop.cloud"
    )
    |> validate_length(:api_key, min: 1, max: 255)
    |> validate_format(:api_key, ~r/^npsws_sk_/,
      message: "must be a Workshop API key beginning with npsws_sk_"
    )
    |> validate_number(:error_email_count, greater_than_or_equal_to: 0)
    |> assoc_constraint(:account)
    |> assoc_constraint(:posture_provider)
    |> unique_constraint(:api_url,
      name: :santa_posture_providers_account_id_api_url_index,
      message: "This Workshop tenant is already connected."
    )
  end

  # The API documentation uses a full tenant origin. Accept a bare hostname or
  # a pasted API path, then store only the canonical HTTPS origin.
  defp normalize_api_url(nil), do: nil

  defp normalize_api_url(api_url) do
    api_url = String.trim(api_url)
    api_url = if URI.parse(api_url).scheme, do: api_url, else: "https://" <> api_url
    uri = URI.parse(api_url)

    if uri.scheme && uri.host do
      %URI{scheme: String.downcase(uri.scheme), host: String.downcase(uri.host), port: uri.port}
      |> URI.to_string()
      |> String.trim_trailing("/")
    else
      api_url
    end
  end
end
