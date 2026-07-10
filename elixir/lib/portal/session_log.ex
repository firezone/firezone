defmodule Portal.SessionLog do
  # credo:disable-for-this-file Credo.Check.Warning.MissingChangesetFunction
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id

  schema "session_logs" do
    belongs_to :account, Portal.Account, primary_key: true
    field :log_id, Portal.Types.LogId, primary_key: true
    field :timestamp, :utc_datetime_usec
    field :context, Ecto.Enum, values: [:client, :gateway, :portal]

    # Snapshot of who connected and from where, taken at session creation.
    # Mirrors the `subject` shape used by change_logs and api_request_logs, so
    # the log survives actor/device/token deletion. Actor filters read
    # `subject->>'actor_id'` / `subject->>'actor_email'`.
    field :subject, :map
  end
end
