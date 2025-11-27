defmodule Domain.Ops do
  alias __MODULE__.DB
  def sync_pricing_plans do
    {:ok, subscriptions} = Domain.Billing.list_all_subscriptions()

    Enum.each(subscriptions, fn subscription ->
      %{
        "object" => "event",
        "data" => %{
          "object" => subscription
        },
        "type" => "customer.subscription.updated"
      }
      |> Domain.Billing.EventHandler.handle_event()
    end)
  end

  @doc """
  To delete an account you need to disable it first by cancelling its subscription in Stripe.
  """
  def delete_disabled_account(id) do
    DB.get_disabled_account!(id)
    |> Domain.Repo.delete(timeout: :infinity)

    :ok
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.Accounts.Account

    def get_disabled_account!(id) do
      from(a in Account,
        where: a.id == ^id,
        where: not is_nil(a.disabled_at)
      )
      |> Domain.Repo.one!()
    end
  end
end
