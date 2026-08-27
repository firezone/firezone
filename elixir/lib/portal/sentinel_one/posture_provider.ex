defmodule Portal.SentinelOne.PostureProvider do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "sentinelone_posture_providers" do
    belongs_to :account, Portal.Account, primary_key: true

    # Shares its id with the posture_providers row; set both when creating.
    field :id, :binary_id, primary_key: true

    belongs_to :posture_provider, Portal.PostureProvider,
      foreign_key: :id,
      define_field: false

    field :name, :string, virtual: true, default: "SentinelOne"
    field :management_url, :string
    field :api_token, :string, redact: true
    field :is_verified, :boolean, default: false, read_after_writes: true
    field :is_disabled, :boolean, default: false, read_after_writes: true
    field :disabled_reason, :string
    field :synced_at, :utc_datetime_usec
    field :errored_at, :utc_datetime_usec
    field :error_message, :string
    field :error_email_count, :integer, default: 0, read_after_writes: true

    has_many :devices, Portal.SentinelOne.Device,
      foreign_key: :posture_provider_id,
      references: :id

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> update_change(:management_url, &normalize_management_url/1)
    |> validate_required([:management_url, :api_token, :is_verified])
    |> validate_length(:management_url, min: 1, max: 255)
    |> validate_format(
      :management_url,
      ~r/^https:\/\/(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+sentinelone\.net$/,
      message: "must be a SentinelOne management URL, such as https://acme.sentinelone.net"
    )
    |> validate_length(:api_token, min: 1, max: 4096)
    |> validate_number(:error_email_count, greater_than_or_equal_to: 0)
    |> assoc_constraint(:account)
    |> assoc_constraint(:posture_provider)
    |> unique_constraint(:management_url,
      name: :sentinelone_posture_providers_account_id_management_url_index,
      message: "This SentinelOne tenant is already connected."
    )
  end

  # Accept a pasted dashboard or API URL, but store only the canonical HTTPS
  # origin. Restricting the host to SentinelOne also keeps this admin-entered
  # URL from becoming an SSRF primitive in the background worker.
  defp normalize_management_url(nil), do: nil

  defp normalize_management_url(management_url) do
    management_url = String.trim(management_url)

    management_url =
      if URI.parse(management_url).scheme,
        do: management_url,
        else: "https://" <> management_url

    uri = URI.parse(management_url)

    if uri.scheme && uri.host do
      %URI{scheme: String.downcase(uri.scheme), host: String.downcase(uri.host), port: uri.port}
      |> URI.to_string()
      |> String.trim_trailing("/")
    else
      management_url
    end
  end
end
