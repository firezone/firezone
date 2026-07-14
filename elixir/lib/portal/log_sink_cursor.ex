defmodule Portal.LogSinkCursor do
  @moduledoc """
  Delivery frontier for one (sink, stream, phase). `cursor` is the highest seq
  already delivered; rows with a greater seq are pending. A `:live` row tails
  new entries forever; a `:backfill` row walks the history that existed when
  the sink was first synced, bounded by `until_seq`, and is done when
  `completed_at` is set.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "log_sink_cursors" do
    belongs_to :account, Portal.Account, primary_key: true

    belongs_to :log_sink, Portal.LogSink,
      foreign_key: :log_sink_id,
      references: :id,
      primary_key: true

    field :stream, Ecto.Enum, values: ~w[change session api_request flow]a, primary_key: true
    field :phase, Ecto.Enum, values: ~w[live backfill]a, primary_key: true

    field :cursor, :integer, default: 0
    field :until_seq, :integer
    field :synced_count, :integer, default: 0
    field :dropped_count, :integer, default: 0
    field :backfill_total, :integer
    field :completed_at, :utc_datetime_usec
    field :last_synced_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required(~w[stream phase cursor]a)
    |> validate_number(:cursor, greater_than_or_equal_to: 0)
    |> assoc_constraint(:account)
    |> check_constraint(:stream, name: :stream_must_be_valid, message: "is not valid")
    |> check_constraint(:phase, name: :phase_must_be_valid, message: "is not valid")
  end
end
