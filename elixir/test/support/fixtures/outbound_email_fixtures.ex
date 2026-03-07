defmodule Portal.OutboundEmailFixtures do
  alias Portal.Repo

  @default_request %{
    "to" => [%{"name" => "", "address" => "to@test.com"}],
    "cc" => [],
    "bcc" => [],
    "from" => %{"name" => "", "address" => "from@test.com"},
    "subject" => "Test Subject",
    "html_body" => nil,
    "text_body" => "hello"
  }

  def outbound_email_fixture(account, attrs \\ []) do
    defaults = [
      account_id: account.id,
      priority: :later,
      status: :pending,
      request: @default_request
    ]

    Repo.insert!(struct(Portal.OutboundEmail, Keyword.merge(defaults, attrs)))
  end
end
