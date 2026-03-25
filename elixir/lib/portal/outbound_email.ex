defmodule Portal.OutboundEmail do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "outbound_emails" do
    belongs_to(:account, Portal.Account, primary_key: true)
    field(:message_id, :string, primary_key: true)

    has_many(:deliveries, Portal.OutboundEmailDelivery,
      references: :message_id,
      foreign_key: :message_id
    )

    field(:subject, :string)
    field(:recipients, {:array, :string})

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:message_id, :subject, :recipients])
    |> assoc_constraint(:account)
    |> unique_constraint([:account_id, :message_id], name: :outbound_emails_pkey)
  end
end
