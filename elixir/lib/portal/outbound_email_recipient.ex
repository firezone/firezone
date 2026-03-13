defmodule Portal.OutboundEmailRecipient do
  @moduledoc """
  Recipient-level delivery state for a tracked outbound email message.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "outbound_email_recipients" do
    belongs_to(:account, Portal.Account, primary_key: true)
    field(:message_id, :string, primary_key: true)
    field(:email, :string, primary_key: true)

    belongs_to(:outbound_email, Portal.OutboundEmail,
      define_field: false,
      references: :message_id,
      foreign_key: :message_id,
      type: :string
    )

    field(:status, Ecto.Enum,
      values: [:pending, :delivered, :bounced, :suppressed, :failed],
      default: :pending
    )

    field(:last_event_at, :utc_datetime_usec)
    field(:failure_code, :string)
    field(:failure_message, :string)

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> assoc_constraint(:account)
    |> assoc_constraint(:outbound_email)
  end
end
