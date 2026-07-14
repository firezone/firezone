defmodule Portal.NewRelic.LogSink do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @regions ~w[US EU FedRAMP]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t(),
          name: String.t(),
          region: String.t(),
          license_key: String.t(),
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

  schema "newrelic_log_sinks" do
    belongs_to :account, Portal.Account, primary_key: true

    # Shares its id with the log_sinks row; set both when creating.
    field :id, :binary_id, primary_key: true

    belongs_to :log_sink, Portal.LogSink,
      foreign_key: :id,
      define_field: false

    field :name, :string, default: "New Relic"
    field :region, :string, default: "US"
    field :license_key, :string, redact: true

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

  def regions, do: @regions

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([
      :name,
      :region,
      :license_key,
      :enabled_streams
    ])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:license_key, min: 1, max: 255)
    |> validate_length(:enabled_streams, min: 1)
    |> validate_number(:error_email_count, greater_than_or_equal_to: 0)
    |> validate_inclusion(:region, @regions)
    |> assoc_constraint(:account)
    |> assoc_constraint(:log_sink)
    |> unique_constraint(:name,
      name: :newrelic_log_sinks_account_id_name_index,
      message: "A New Relic log sink with this name already exists."
    )
  end
end
