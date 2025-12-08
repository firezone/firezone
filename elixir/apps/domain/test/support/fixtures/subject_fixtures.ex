defmodule Domain.SubjectFixtures do
  @moduledoc """
  Test helpers for building auth subjects.
  """

  import Domain.AccountFixtures
  import Domain.ActorFixtures
  import Domain.TokenFixtures

  alias Domain.Auth.Context
  alias Domain.Auth.Subject

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

    %Subject{
      actor: actor,
      account: account,
      expires_at: token.expires_at,
      context: context,
      token_id: token.id
    }
  end

  @doc """
  Build an admin auth subject.
  """
  def admin_subject_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{actor: %{type: :account_admin_user}})
    subject_fixture(attrs)
  end

  defp actor_token_type(:service_account), do: :client
  defp actor_token_type(:api_client), do: :api_client
  defp actor_token_type(_), do: :browser

  @doc """
  Build an auth context with sensible defaults.
  """
  def build_context(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {type, attrs} = Map.pop(attrs, :type, :browser)
    {user_agent, attrs} = Map.pop(attrs, :user_agent, "Mozilla/5.0")
    {remote_ip, attrs} = Map.pop(attrs, :remote_ip, {100, 64, 0, 1})

    {remote_ip_location_region, attrs} =
      Map.pop(attrs, :remote_ip_location_region, "US")

    {remote_ip_location_city, attrs} =
      Map.pop(attrs, :remote_ip_location_city, "San Francisco")

    {remote_ip_location_lat, attrs} =
      Map.pop(attrs, :remote_ip_location_lat, 37.7749)

    {remote_ip_location_lon, _attrs} =
      Map.pop(attrs, :remote_ip_location_lon, -122.4194)

    %Context{
      type: type,
      remote_ip: remote_ip,
      remote_ip_location_region: remote_ip_location_region,
      remote_ip_location_city: remote_ip_location_city,
      remote_ip_location_lat: remote_ip_location_lat,
      remote_ip_location_lon: remote_ip_location_lon,
      user_agent: user_agent
    }
  end
end
