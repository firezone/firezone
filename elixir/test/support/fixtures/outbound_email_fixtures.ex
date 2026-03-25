defmodule Portal.OutboundEmailFixtures do
  alias Portal.Repo

  def outbound_email_fixture(account, attrs \\ []) do
    defaults = [
      account_id: account.id,
      message_id: Ecto.UUID.generate(),
      subject: "Test Subject",
      recipients: ["to@test.com"]
    ]

    merged = Keyword.merge(defaults, attrs)
    entry = Repo.insert!(struct(Portal.OutboundEmail, merged))

    now = DateTime.utc_now()
    account_id = entry.account_id
    message_id = entry.message_id

    delivery_rows =
      Enum.map(entry.recipients, fn email ->
        %{
          account_id: account_id,
          message_id: message_id,
          email: email,
          status: :pending,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(Portal.OutboundEmailDelivery, delivery_rows)

    entry
  end
end
