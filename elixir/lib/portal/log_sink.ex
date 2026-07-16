defmodule Portal.LogSink do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  schema "log_sinks" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true
    field :type, Ecto.Enum, values: ~w[splunk datadog newrelic elastic sentinel s3 qradar]a

    has_one :splunk_log_sink, Portal.Splunk.LogSink,
      references: :id,
      foreign_key: :id

    has_one :datadog_log_sink, Portal.Datadog.LogSink,
      references: :id,
      foreign_key: :id

    has_one :newrelic_log_sink, Portal.NewRelic.LogSink,
      references: :id,
      foreign_key: :id

    has_one :elastic_log_sink, Portal.Elastic.LogSink,
      references: :id,
      foreign_key: :id

    has_one :sentinel_log_sink, Portal.Sentinel.LogSink,
      references: :id,
      foreign_key: :id

    has_one :s3_log_sink, Portal.S3.LogSink,
      references: :id,
      foreign_key: :id

    has_one :qradar_log_sink, Portal.QRadar.LogSink,
      references: :id,
      foreign_key: :id

    has_many :cursors, Portal.LogSinkCursor,
      references: :id,
      foreign_key: :log_sink_id
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required(~w[type]a)
    |> assoc_constraint(:account)
    |> check_constraint(:type, name: :type_must_be_valid, message: "is not valid")
  end
end
