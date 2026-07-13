defmodule Portal.Splunk.LogSink do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t(),
          name: String.t(),
          collector_url: String.t(),
          hec_token: String.t(),
          index: String.t() | nil,
          enabled_streams: [atom()],
          retroactive: boolean(),
          errored_at: DateTime.t() | nil,
          error_message: String.t() | nil,
          is_disabled: boolean(),
          disabled_reason: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "splunk_log_sinks" do
    belongs_to :account, Portal.Account, primary_key: true

    # Shares its id with the log_sinks row; set both when creating.
    field :id, :binary_id, primary_key: true

    belongs_to :log_sink, Portal.LogSink,
      foreign_key: :id,
      define_field: false

    field :name, :string, default: "Splunk"
    field :collector_url, :string
    field :hec_token, :string, redact: true
    field :index, :string

    field :enabled_streams, {:array, Ecto.Enum},
      values: ~w[change session api_request flow]a,
      default: ~w[change session api_request flow]a

    field :retroactive, :boolean, default: false

    field :errored_at, :utc_datetime_usec
    field :error_message, :string
    field :is_disabled, :boolean, default: false, read_after_writes: true
    field :disabled_reason, :string

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([
      :name,
      :collector_url,
      :hec_token,
      :enabled_streams
    ])
    |> update_change(:collector_url, &normalize_collector_url/1)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:collector_url, min: 1, max: 2048)
    |> validate_length(:hec_token, min: 1, max: 255)
    |> validate_length(:index, max: 255)
    |> validate_length(:enabled_streams, min: 1)
    |> validate_collector_url()
    |> assoc_constraint(:account)
    |> assoc_constraint(:log_sink)
    |> unique_constraint(:name,
      name: :splunk_log_sinks_account_id_name_index,
      message: "A Splunk log sink with this name already exists."
    )
  end

  # People paste the full endpoint from the Splunk docs; the client appends
  # the collector path itself, so strip it down to the base URL.
  defp normalize_collector_url(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.replace_suffix("/services/collector/event", "")
    |> String.replace_suffix("/services/collector", "")
    |> String.trim_trailing("/")
  end

  defp validate_collector_url(changeset) do
    validate_change(changeset, :collector_url, fn :collector_url, url ->
      case URI.new(url) do
        {:ok, %URI{scheme: scheme, host: host}}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _ ->
          [collector_url: "must be a valid http(s) URL"]
      end
    end)
  end
end
