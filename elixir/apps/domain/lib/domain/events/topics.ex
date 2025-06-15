defmodule Domain.Events.Topics do
  @moduledoc """
    A simple module to house all of the topics and broadcasts so we can see
    them and verify them in one place.
  """
  alias Domain.PubSub

  defmodule Account do
    def subscribe(account_id) do
      account_id
      |> topic()
      |> PubSub.subscribe()
    end

    defp topic(account_id) do
      "accounts:" <> account_id
    end
  end

  defmodule Presence do
    defmodule Account do
      defmodule Clients do
        def subscribe(account_id) do
          account_id
          |> topic()
          |> PubSub.subscribe()
        end

        defp topic(account_id) do
          "presences:account_clients:" <> account_id
        end
      end

      defmodule Gateways do
        def subscribe(account_id) do
          account_id
          |> topic()
          |> PubSub.subscribe()
        end

        defp topic(account_id) do
          "presences:account_gateways:" <> account_id
        end
      end
    end
  end
end
