defmodule Portal.Sentinel.LogSink do
  use Ecto.Schema
  import Ecto.Changeset
  import Portal.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t(),
          name: String.t(),
          tenant_id: String.t(),
          ingestion_endpoint: String.t(),
          dcr_immutable_id: String.t(),
          stream_name: String.t(),
          enabled_streams: [atom()],
          retroactive: boolean(),
          errored_at: DateTime.t() | nil,
          error_message: String.t() | nil,
          error_email_count: non_neg_integer(),
          last_error_email_at: DateTime.t() | nil,
          is_disabled: boolean(),
          disabled_reason: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "sentinel_log_sinks" do
    belongs_to :account, Portal.Account, primary_key: true

    # Shares its id with the log_sinks row; set both when creating.
    field :id, :binary_id, primary_key: true

    belongs_to :log_sink, Portal.LogSink,
      foreign_key: :id,
      define_field: false

    field :name, :string, default: "Microsoft Sentinel"
    field :tenant_id, :string
    field :ingestion_endpoint, :string
    field :dcr_immutable_id, :string
    field :stream_name, :string, default: "Custom-FirezoneLogs_CL"

    field :enabled_streams, {:array, Ecto.Enum},
      values: ~w[change session api_request flow]a,
      default: ~w[change session api_request flow]a

    field :retroactive, :boolean, default: false

    field :errored_at, :utc_datetime_usec
    field :error_message, :string
    field :error_email_count, :integer, default: 0, read_after_writes: true
    field :last_error_email_at, :utc_datetime_usec
    field :is_disabled, :boolean, default: false, read_after_writes: true
    field :disabled_reason, :string

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> update_change(:tenant_id, &String.trim/1)
    |> update_change(:ingestion_endpoint, &normalize_ingestion_endpoint/1)
    |> update_change(:dcr_immutable_id, &String.trim/1)
    |> update_change(:stream_name, &String.trim/1)
    |> validate_required([
      :name,
      :tenant_id,
      :ingestion_endpoint,
      :dcr_immutable_id,
      :stream_name,
      :enabled_streams
    ])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:ingestion_endpoint, min: 1, max: 2048)
    |> validate_length(:enabled_streams, min: 1)
    |> validate_number(:error_email_count, greater_than_or_equal_to: 0)
    |> validate_format(
      :tenant_id,
      ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/,
      message: "must be a directory (tenant) ID in UUID format"
    )
    |> validate_format(:dcr_immutable_id, ~r/^dcr-[a-f0-9]{32}$/,
      message: "must look like dcr-0123456789abcdef0123456789abcdef"
    )
    |> validate_format(:stream_name, ~r/^Custom-[A-Za-z0-9_.\-]{1,200}$/,
      message: "must start with Custom- followed by the stream name"
    )
    |> validate_uri(:ingestion_endpoint, schemes: ~w[https], block_private_ips: true)
    |> validate_ingestion_host()
    |> assoc_constraint(:account)
    |> assoc_constraint(:log_sink)
    |> unique_constraint(:name,
      name: :sentinel_log_sinks_account_id_name_index,
      message: "A Microsoft Sentinel log sink with this name already exists."
    )
  end

  defp normalize_ingestion_endpoint(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
  end

  # Each delivery mints a bearer token from Firezone's shared Entra credentials
  # scoped to Azure Monitor, so the endpoint must be an Azure Monitor ingestion
  # host: a stray URL would receive that token.
  defp validate_ingestion_host(changeset) do
    validate_change(changeset, :ingestion_endpoint, fn :ingestion_endpoint, value ->
      case ingestion_host_error(value) do
        nil -> []
        error -> [ingestion_endpoint: error]
      end
    end)
  end

  defp ingestion_host_error(value) do
    case URI.new(value) do
      {:ok, %URI{host: host}} when is_binary(host) -> azure_host_error(host)
      _ -> nil
    end
  end

  defp azure_host_error(host) do
    if String.ends_with?(String.downcase(host), ".ingest.monitor.azure.com") do
      nil
    else
      "must be an Azure Monitor endpoint ending in .ingest.monitor.azure.com"
    end
  end

end
