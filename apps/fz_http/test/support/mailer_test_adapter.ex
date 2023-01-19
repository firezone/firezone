defmodule FzHttpWeb.MailerTestAdapter do
  use Swoosh.Adapter

  @impl true
  def deliver(email, config) do
    Swoosh.Adapters.Local.deliver(email, config)
    Swoosh.Adapters.Test.deliver(email, config)
  end

  @impl true
  def deliver_many(emails, config) do
    Swoosh.Adapters.Local.deliver_many(emails, config)
    Swoosh.Adapters.Test.deliver_many(emails, config)
  end
end
