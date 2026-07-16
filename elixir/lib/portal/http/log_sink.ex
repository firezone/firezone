defmodule Portal.HTTP.LogSink do
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
          endpoint_url: String.t(),
          bearer_token: String.t() | nil,
          batch_max_events: pos_integer(),
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

  schema "http_log_sinks" do
    belongs_to :account, Portal.Account, primary_key: true

    # Shares its id with the log_sinks row; set both when creating.
    field :id, :binary_id, primary_key: true

    belongs_to :log_sink, Portal.LogSink,
      foreign_key: :id,
      define_field: false

    field :name, :string, default: "HTTP"
    field :endpoint_url, :string
    field :bearer_token, :string, redact: true
    field :batch_max_events, :integer, default: 100

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
    |> update_change(:endpoint_url, &String.trim/1)
    |> update_change(:bearer_token, &normalize_bearer_token/1)
    |> validate_required([
      :name,
      :endpoint_url,
      :batch_max_events,
      :enabled_streams
    ])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:endpoint_url, min: 1, max: 2048)
    |> validate_length(:bearer_token, max: 4096)
    |> validate_inclusion(:batch_max_events, 1..1000)
    |> validate_length(:enabled_streams, min: 1)
    |> validate_number(:error_email_count, greater_than_or_equal_to: 0)
    |> validate_uri(:endpoint_url, schemes: ~w[https], block_private_ips: true)
    |> assoc_constraint(:account)
    |> assoc_constraint(:log_sink)
    |> unique_constraint(:name,
      name: :http_log_sinks_account_id_name_index,
      message: "An HTTP log sink with this name already exists."
    )
  end

  defp normalize_bearer_token(token) do
    case String.trim(token) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
