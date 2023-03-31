defmodule Domain.Mailer.NoopAdapter do
  @moduledoc """
  When mailer is not configure, use noop adapter as a drop-in replacement
  so that we don't have to add conditional logic to every single call to
  `Web.Mailer.deliver/2`.

  # XXX: Having this module in the Domain app is a workaround for the following issue:
  # https://github.com/elixir-lang/elixir/issues/12777
  # Move this module back to the Web app once this is fixed.
  """
  use Swoosh.Adapter
  require Logger

  @impl true
  def deliver(email, _opts) do
    Logger.info("Mailer is not configured, dropping email: #{inspect(email)}")
    {:ok, %{}}
  end
end
