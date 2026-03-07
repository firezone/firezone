defmodule Portal.OutboundEmailRecipient do
  @moduledoc """
  Recipient-level delivery state for a queued email message.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "outbound_email_recipients" do
    field(:id, :binary_id, primary_key: true, autogenerate: true)
    belongs_to(:account, Portal.Account)

    belongs_to(:outbound_email, Portal.OutboundEmail,
      references: :id,
      foreign_key: :outbound_email_id
    )

    field(:kind, Ecto.Enum, values: [:to, :cc, :bcc])

    field(:status, Ecto.Enum,
      values: [:pending, :delivered, :bounced, :suppressed, :failed],
      default: :pending
    )

    field(:email, :string)
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
