defmodule Portal.OutboundEmail do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "outbound_emails" do
    belongs_to(:account, Portal.Account, primary_key: true)
    field(:id, :binary_id, primary_key: true, autogenerate: true)

    has_many(:recipients, Portal.OutboundEmailRecipient,
      references: :id,
      foreign_key: :outbound_email_id
    )

    field(:priority, Ecto.Enum, values: [:now, :later])

    field(:status, Ecto.Enum,
      values: [:pending, :running, :succeeded, :failed, :errored],
      default: :pending
    )

    field(:request, :map, redact: true)
    field(:response, :map, redact: true)
    field(:last_attempted_at, :utc_datetime_usec)
    field(:message_id, :string)
    field(:failed_at, :utc_datetime_usec)

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> assoc_constraint(:account)
  end
end
