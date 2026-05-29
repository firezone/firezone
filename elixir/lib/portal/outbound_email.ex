defmodule Portal.OutboundEmail do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:message_id, :string, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "outbound_emails" do
    belongs_to(:account, Portal.Account)

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
    |> unique_constraint(:message_id, name: :outbound_emails_pkey)
  end
end
