defmodule Portal.OutboundEmail do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "outbound_emails" do
    belongs_to(:account, Portal.Account, primary_key: true)
    field(:message_id, :string, primary_key: true)

    has_many(:recipients, Portal.OutboundEmailRecipient,
      references: :message_id,
      foreign_key: :message_id
    )

    field(:priority, Ecto.Enum, values: [:now, :later])

    field(:status, Ecto.Enum,
      values: [:running, :succeeded, :failed],
      default: :running
    )

    field(:request, :map, redact: true)
    field(:response, :map, redact: true)
    field(:failed_at, :utc_datetime_usec)

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> assoc_constraint(:account)
    |> unique_constraint([:account_id, :message_id], name: :outbound_emails_pkey)
    |> unique_constraint(:message_id, name: :outbound_emails_message_id_index)
  end
end
