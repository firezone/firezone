defmodule Domain.PubSub do
  @moduledoc """
  A wrapper around Phoenix.PubSub that allows us not to spread the knowledge of the process name
  across applications.
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  def init(_opts) do
    children = [
      {Phoenix.PubSub, name: __MODULE__}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  See `Phoenix.PubSub.broadcast/3`.

  Keep in mind that Phoenix.Presence is also using the same PubSub process,
  so you can broadcast to Phoenix.Presence topics as well. This feature is
  used in some of domain contexts.
  """
  def broadcast(topic, payload) do
    Phoenix.PubSub.broadcast(__MODULE__, topic, payload)
  end

  @doc """
  See `Phoenix.PubSub.subscribe/2`.
  """
  def subscribe(topic) do
    Phoenix.PubSub.subscribe(__MODULE__, topic)
  end

  @doc """
  See `Phoenix.PubSub.unsubscribe/2`.
  """
  def unsubscribe(topic) do
    Phoenix.PubSub.unsubscribe(__MODULE__, topic)
  end

  # TODO: These are quite repetitive. We could simplify this with a `__using__` macro.
  defmodule Account do
    def subscribe(account_id) do
      account_id
      |> topic()
      |> Domain.PubSub.subscribe()
    end

    def broadcast(account_id, payload) do
      account_id
      |> topic()
      |> Domain.PubSub.broadcast(payload)
    end

    defp topic(account_id) do
      Atom.to_string(__MODULE__) <> ":" <> account_id
    end

    defmodule Clients do
      def subscribe(account_id) do
        account_id
        |> topic()
        |> Domain.PubSub.subscribe()
      end

      def broadcast(account_id, payload) do
        account_id
        |> topic()
        |> Domain.PubSub.broadcast(payload)
      end

      def disconnect(account_id) do
        account_id
        |> topic()
        |> Domain.PubSub.broadcast("disconnect")
      end

      defp topic(account_id) do
        Atom.to_string(__MODULE__) <> ":" <> account_id
      end
    end

    defmodule Policies do
      def subscribe(account_id) do
        account_id
        |> topic()
        |> Domain.PubSub.subscribe()
      end

      def broadcast(account_id, payload) do
        account_id
        |> topic()
        |> Domain.PubSub.broadcast(payload)
      end

      defp topic(account_id) do
        Atom.to_string(__MODULE__) <> ":" <> account_id
      end
    end

    defmodule Resources do
      def subscribe(account_id) do
        account_id
        |> topic()
        |> Domain.PubSub.subscribe()
      end

      def broadcast(account_id, payload) do
        account_id
        |> topic()
        |> Domain.PubSub.broadcast(payload)
      end

      defp topic(account_id) do
        Atom.to_string(__MODULE__) <> ":" <> account_id
      end
    end
  end

  defmodule Actor do
    def subscribe(actor_id) do
      actor_id
      |> topic()
      |> Domain.PubSub.subscribe()
    end

    defp topic(actor_id) do
      Atom.to_string(__MODULE__) <> ":" <> actor_id
    end

    defmodule Memberships do
      def subscribe(actor_id) do
        actor_id
        |> topic()
        |> Domain.PubSub.subscribe()
      end

      def broadcast(actor_id, payload) do
        actor_id
        |> topic()
        |> Domain.PubSub.broadcast(payload)
      end

      def broadcast_access(action, actor_id, group_id) do
        Domain.Policies.Policy.Query.not_deleted()
        |> Domain.Policies.Policy.Query.by_actor_group_id(group_id)
        |> Domain.Repo.all()
        |> Enum.each(fn policy ->
          payload = {:"#{action}_access", policy.id, policy.actor_group_id, policy.resource_id}
          :ok = Actor.Policies.broadcast(actor_id, payload)
        end)
      end

      defp topic(actor_id) do
        Atom.to_string(__MODULE__) <> ":" <> actor_id
      end
    end

    defmodule Policies do
      def subscribe(actor_id) do
        actor_id
        |> topic()
        |> Domain.PubSub.subscribe()
      end

      def broadcast(actor_id, payload) do
        actor_id
        |> topic()
        |> Domain.PubSub.broadcast(payload)
      end

      defp topic(actor_id) do
        Atom.to_string(__MODULE__) <> ":" <> actor_id
      end
    end
  end

  defmodule ActorGroup do
    defmodule Policies do
      def subscribe(actor_group_id) do
        actor_group_id
        |> topic()
        |> Domain.PubSub.subscribe()
      end

      def unsubscribe(actor_group_id) do
        actor_group_id
        |> topic()
        |> Domain.PubSub.unsubscribe()
      end

      def broadcast(actor_group_id, payload) do
        actor_group_id
        |> topic()
        |> Domain.PubSub.broadcast(payload)
      end

      defp topic(actor_group_id) do
        Atom.to_string(__MODULE__) <> ":" <> actor_group_id
      end
    end
  end

  defmodule Client do
    def subscribe(client_id) do
      client_id
      |> topic()
      |> Domain.PubSub.subscribe()
    end

    def broadcast(client_id, payload) do
      client_id
      |> topic()
      |> Domain.PubSub.broadcast(payload)
    end

    def disconnect(client_id) do
      client_id
      |> topic()
      |> Domain.PubSub.broadcast("disconnect")
    end

    defp topic(client_id) do
      Atom.to_string(__MODULE__) <> ":" <> client_id
    end
  end

  defmodule Flow do
    def subscribe(flow_id) do
      flow_id
      |> topic()
      |> Domain.PubSub.subscribe()
    end

    def unsubscribe(flow_id) do
      flow_id
      |> topic()
      |> Domain.PubSub.unsubscribe()
    end

    def broadcast(flow_id, payload) do
      flow_id
      |> topic()
      |> Domain.PubSub.broadcast(payload)
    end

    defp topic(flow_id) do
      Atom.to_string(__MODULE__) <> ":" <> flow_id
    end
  end

  defmodule GatewayGroup do
    def subscribe(gateway_group_id) do
      gateway_group_id
      |> topic()
      |> Domain.PubSub.subscribe()
    end

    def unsubscribe(gateway_group_id) do
      gateway_group_id
      |> topic()
      |> Domain.PubSub.unsubscribe()
    end

    defp topic(gateway_group_id) do
      Atom.to_string(__MODULE__) <> ":" <> gateway_group_id
    end
  end

  defmodule Gateway do
    def subscribe(gateway_id) do
      gateway_id
      |> topic()
      |> Domain.PubSub.subscribe()
    end

    def broadcast(gateway_id, payload) do
      gateway_id
      |> topic()
      |> Domain.PubSub.broadcast(payload)
    end

    def disconnect(gateway_id) do
      gateway_id
      |> topic()
      |> Domain.PubSub.broadcast("disconnect")
    end

    defp topic(gateway_id) do
      Atom.to_string(__MODULE__) <> ":" <> gateway_id
    end
  end

  defmodule Policy do
    def subscribe(policy_id) do
      policy_id
      |> topic()
      |> Domain.PubSub.subscribe()
    end

    def broadcast(policy_id, payload) do
      policy_id
      |> topic()
      |> Domain.PubSub.broadcast(payload)
    end

    defp topic(policy_id) do
      Atom.to_string(__MODULE__) <> ":" <> policy_id
    end
  end

  defmodule Resource do
    def subscribe(resource_id) do
      resource_id
      |> topic()
      |> Domain.PubSub.subscribe()
    end

    def unsubscribe(resource_id) do
      resource_id
      |> topic()
      |> Domain.PubSub.unsubscribe()
    end

    def broadcast(resource_id, payload) do
      resource_id
      |> topic()
      |> Domain.PubSub.broadcast(payload)
    end

    defp topic(resource_id) do
      Atom.to_string(__MODULE__) <> ":" <> resource_id
    end
  end

  defmodule Token do
    def disconnect(token_id) do
      token_id
      |> topic()
      |> Domain.PubSub.broadcast(%Phoenix.Socket.Broadcast{
        topic: topic(token_id),
        event: "disconnect"
      })
    end

    defp topic(token_id) do
      # This topic is managed by Phoenix
      Domain.Tokens.socket_id(token_id)
    end
  end
end
