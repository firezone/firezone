defmodule Portal.Elastic.LogSink do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t(),
          name: String.t(),
          endpoint_url: String.t(),
          api_key: String.t(),
          data_stream: String.t(),
          enabled_streams: [atom()],
          retroactive: boolean(),
          errored_at: DateTime.t() | nil,
          error_message: String.t() | nil,
          error_email_count: non_neg_integer(),
          last_error_email_at: DateTime.t() | nil,
          last_rollover_at: DateTime.t() | nil,
          is_disabled: boolean(),
          disabled_reason: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "elastic_log_sinks" do
    belongs_to :account, Portal.Account, primary_key: true

    # Shares its id with the log_sinks row; set both when creating.
    field :id, :binary_id, primary_key: true

    belongs_to :log_sink, Portal.LogSink,
      foreign_key: :id,
      define_field: false

    field :name, :string, default: "Elastic"
    field :endpoint_url, :string
    field :api_key, :string, redact: true
    field :data_stream, :string, default: "logs-firezone-default"

    field :enabled_streams, {:array, Ecto.Enum},
      values: ~w[change session api_request flow]a,
      default: ~w[change session api_request flow]a

    field :retroactive, :boolean, default: false

    field :errored_at, :utc_datetime_usec
    field :error_message, :string
    field :error_email_count, :integer, default: 0, read_after_writes: true
    field :last_error_email_at, :utc_datetime_usec
    field :last_rollover_at, :utc_datetime_usec
    field :is_disabled, :boolean, default: false, read_after_writes: true
    field :disabled_reason, :string

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> update_change(:endpoint_url, &normalize_endpoint_url/1)
    |> validate_required([
      :name,
      :endpoint_url,
      :api_key,
      :data_stream,
      :enabled_streams
    ])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:endpoint_url, min: 1, max: 2048)
    |> validate_length(:api_key, min: 1, max: 255)
    |> validate_length(:enabled_streams, min: 1)
    |> validate_number(:error_email_count, greater_than_or_equal_to: 0)
    |> validate_endpoint_url()
    |> validate_format(:data_stream, ~r/^[a-z0-9][a-z0-9._-]{0,254}$/,
      message: "must be a valid lowercase data stream name"
    )
    |> assoc_constraint(:account)
    |> assoc_constraint(:log_sink)
    |> unique_constraint(:name,
      name: :elastic_log_sinks_account_id_name_index,
      message: "An Elastic log sink with this name already exists."
    )
  end

  defp normalize_endpoint_url(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.replace_suffix("/_bulk", "")
    |> String.trim_trailing("/")
  end

  defp validate_endpoint_url(changeset) do
    validate_change(changeset, :endpoint_url, fn :endpoint_url, url ->
      case URI.new(url) do
        {:ok, %URI{scheme: scheme, host: host}}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _ ->
          [endpoint_url: "must be a valid http(s) URL"]
      end
    end)
  end
end
