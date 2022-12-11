defmodule FzHttp.AllowRulesFixtures do
  @moduledoc """
  Test helpers for creating allow rules with the `FzHttp.AllowRules` context.
  """

  alias FzHttp.AllowRules

  import FzHttp.GatewaysFixtures

  @doc """
  Generate an `AllowRule`.
  """
  def allow_rule(attrs \\ %{}) do
    gateway_id =
      Map.get_lazy(
        attrs,
        :gateway_id,
        fn -> gateway(%{}).id end
      )

    {:ok, allow_rule} =
      attrs
      |> Enum.into(%{destination: "10.10.10.0/24", gateway_id: gateway_id})
      |> AllowRules.create_allow_rule()

    allow_rule
  end
end
