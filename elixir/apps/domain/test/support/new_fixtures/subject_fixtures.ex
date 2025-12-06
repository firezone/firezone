defmodule Domain.SubjectFixtures do
  @moduledoc """
  Test helpers for building auth subjects.
  """

  import Domain.AccountFixtures
  import Domain.ActorFixtures
  import Domain.TokenFixtures

  alias Domain.Auth
  alias Domain.Auth.Context

  @doc """
  Build an auth subject with sensible defaults.
  """
  def subject_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    account = Map.get(attrs, :account) || account_fixture()

    actor =
      case Map.get(attrs, :actor) do
        %Domain.Actor{} = actor ->
          actor

        actor_attrs when is_map(actor_attrs) or is_list(actor_attrs) ->
          actor_attrs
          |> Enum.into(%{})
          |> Map.put_new(:account, account)
          |> actor_fixture()

        nil ->
          actor_fixture(account: account)
      end

    token_type = Map.get(attrs, :type) || actor_token_type(actor.type)

    context =
      Map.get_lazy(attrs, :context, fn ->
        %Context{
          type: token_type,
          remote_ip: Map.get(attrs, :remote_ip, {100, 64, 0, 1}),
          remote_ip_location_region: Map.get(attrs, :remote_ip_location_region, "US"),
          remote_ip_location_city: Map.get(attrs, :remote_ip_location_city, "San Francisco"),
          remote_ip_location_lat: Map.get(attrs, :remote_ip_location_lat, 37.7749),
          remote_ip_location_lon: Map.get(attrs, :remote_ip_location_lon, -122.4194),
          user_agent: Map.get(attrs, :user_agent, "Mozilla/5.0")
        }
      end)

    token =
      Map.get_lazy(attrs, :token, fn ->
        token_attrs =
          attrs
          |> Map.take([:expires_at, :name])
          |> Enum.into(%{
            type: token_type,
            account: account,
            actor: actor
          })

        token_fixture(token_attrs)
      end)

    {:ok, subject} = Auth.build_subject(token, context)
    subject
  end

  @doc """
  Build an admin auth subject.
  """
  def admin_subject_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    subject_fixture(Map.put_new(attrs, :actor, %{type: :account_admin_user}))
  end

  defp actor_token_type(:service_account), do: :client
  defp actor_token_type(:api_client), do: :api_client
  defp actor_token_type(_), do: :browser
end
