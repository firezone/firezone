defmodule PortalWeb.Unsubscribe do
  use PortalWeb, {:live_view, layout: false}
  alias Portal.UnsubscribeToken
  alias __MODULE__.Database

  @notification_labels %{
    outdated_gateways: "Gateway upgrade available",
    seat_limit_warnings: "Seat limit warnings",
    product_announcements: "Product announcements",
    product_feedback_requests: "Product feedback requests"
  }

  # Mail scanners fetch links in emails without running scripts, so the email
  # is turned off only once the LiveView connects.
  def mount(%{"token" => token}, _session, socket) do
    socket = assign(socket, page_title: "Turn off notifications", result: :pending)

    if connected?(socket) do
      {:ok, assign(socket, result: unsubscribe(socket.assigns[:account], token))}
    else
      {:ok, socket}
    end
  end

  def render(%{result: :pending} = assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center px-4 bg-surface">
      <div class="flex items-center gap-2 text-subtle">
        <Core.icon name="ri-loader-4-line" class="w-5 h-5 animate-spin" />
        <span>Turning off notifications...</span>
      </div>
    </div>
    """
  end

  def render(%{result: {:ok, notification}} = assigns) do
    assigns = assign(assigns, :label, Map.fetch!(@notification_labels, notification))

    ~H"""
    <Core.result_page success title="Notifications turned off">
      <p class="mt-2 text-base text-subtle">
        You will no longer get <span class="font-semibold text-heading">{@label}</span>
        emails for the <span class="font-semibold text-heading">{@account.name}</span>
        account.
      </p>
      <.notification_settings_link account={@account} />
    </Core.result_page>
    """
  end

  def render(%{result: :error} = assigns) do
    ~H"""
    <Core.result_page success={false} title="Link not valid">
      <p class="mt-2 text-base text-subtle">
        This link is not valid or has expired.
      </p>
      <.notification_settings_link :if={assigns[:account]} account={@account} />
    </Core.result_page>
    """
  end

  attr :account, :any, required: true

  defp notification_settings_link(assigns) do
    ~H"""
    <p class="mt-6">
      <.link
        navigate={~p"/#{@account}/settings/profile"}
        class="text-sm font-medium text-brand hover:underline"
      >
        Manage your notifications
      </.link>
    </p>
    """
  end

  defp unsubscribe(nil, _token), do: :error

  defp unsubscribe(account, token) do
    with {:ok, {account_id, actor_id, notification}} when account_id == account.id <-
           UnsubscribeToken.verify(token),
         {:ok, _actor} <- Database.turn_off_email(account_id, actor_id, notification) do
      {:ok, notification}
    else
      _other -> :error
    end
  end

  defmodule Database do
    import Ecto.Changeset
    import Ecto.Query
    alias Portal.{Actor, Safe}
    alias Portal.Actor.Preferences

    def turn_off_email(account_id, actor_id, notification) do
      Safe.transact(fn ->
        from(a in Actor,
          where: a.account_id == ^account_id,
          where: a.id == ^actor_id,
          lock: "FOR UPDATE"
        )
        |> Safe.unscoped()
        |> Safe.one()
        |> case do
          nil ->
            {:error, :not_found}

          actor ->
            actor
            |> changeset(notification)
            |> Safe.unscoped()
            |> Safe.update()
        end
      end)
    end

    defp changeset(actor, notification) do
      channels = Preferences.channels(actor.preferences, notification) -- [:email]

      actor
      |> cast(%{preferences: %{notifications: %{notification => channels}}}, [])
      |> cast_embed(:preferences,
        with: fn preferences, attrs ->
          (preferences || %Preferences{})
          |> cast(attrs, [])
          |> cast_embed(:notifications,
            with: fn notifications, attrs ->
              cast(notifications || %Preferences.Notifications{}, attrs, [notification])
            end
          )
        end
      )
    end
  end
end
