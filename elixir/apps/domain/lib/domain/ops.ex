defmodule Domain.Ops do
  alias __MODULE__.DB
  alias Domain.Banner

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

  def set_banner(message) do
    clear_banner()

    %Banner{}
    |> Banner.changeset(message: message)
    |> DB.insert()
  end

  def clear_banner do
    DB.delete_all(Banner)
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.{Account, Safe}

    def get_disabled_account!(id) do
      from(a in Account,
        where: a.id == ^id,
        where: not is_nil(a.disabled_at)
      )
      |> Safe.unscoped()
      |> Safe.one!()
    end

    def insert(changeset) do
      changeset
      |> Safe.unscoped()
      |> Safe.insert()
    end

    def delete_all(schema) do
      from(s in schema)
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
