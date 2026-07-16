defmodule Portal.S3.LogSink do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t(),
          name: String.t(),
          bucket: String.t(),
          region: String.t(),
          role_arn: String.t(),
          key_prefix: String.t() | nil,
          external_id: Ecto.UUID.t(),
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

  schema "s3_log_sinks" do
    belongs_to :account, Portal.Account, primary_key: true

    # Shares its id with the log_sinks row; set both when creating.
    field :id, :binary_id, primary_key: true

    belongs_to :log_sink, Portal.LogSink,
      foreign_key: :id,
      define_field: false

    field :name, :string, default: "Amazon S3"
    field :bucket, :string
    field :region, :string
    field :role_arn, :string
    field :key_prefix, :string
    field :external_id, Ecto.UUID

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
    |> update_change(:key_prefix, &normalize_key_prefix/1)
    |> validate_required([
      :name,
      :bucket,
      :region,
      :role_arn,
      :external_id,
      :enabled_streams
    ])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_format(:bucket, ~r/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/,
      message: "must be a valid S3 bucket name"
    )
    |> validate_length(:region, min: 1, max: 64)
    |> validate_format(:region, ~r/^[a-z0-9-]+$/,
      message: "must be a valid AWS region, e.g. us-east-1"
    )
    |> validate_length(:role_arn, min: 1, max: 2048)
    |> validate_format(:role_arn, ~r"^arn:(aws|aws-us-gov):iam::\d{12}:role/[\w+=,.@/-]+$",
      message: "must be an IAM role ARN, e.g. arn:aws:iam::123456789012:role/firezone-logs"
    )
    |> validate_length(:key_prefix, max: 512)
    |> validate_length(:enabled_streams, min: 1)
    |> validate_number(:error_email_count, greater_than_or_equal_to: 0)
    |> assoc_constraint(:account)
    |> assoc_constraint(:log_sink)
    |> unique_constraint(:name,
      name: :s3_log_sinks_account_id_name_index,
      message: "An Amazon S3 log sink with this name already exists."
    )
  end

  defp normalize_key_prefix(prefix) do
    normalized = prefix |> String.trim() |> String.trim("/")

    if normalized == "" do
      nil
    else
      normalized
    end
  end
end
