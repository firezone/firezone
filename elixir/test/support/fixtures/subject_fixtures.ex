defmodule Portal.SubjectFixtures do
  @moduledoc """
  Test helpers for building auth subjects.
  """

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.TokenFixtures
  import Portal.PortalSessionFixtures

  alias Portal.Authentication.Context
  alias Portal.Authentication.Credential
  alias Portal.Authentication.Subject

  @doc """
  Build an auth subject with sensible defaults.
  """
  def subject_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    account = Map.get(attrs, :account) || account_fixture()

    actor =
      case Map.get(attrs, :actor) do
        %Portal.Actor{} = actor ->
          actor

        actor_attrs when is_map(actor_attrs) or is_list(actor_attrs) ->
          actor_attrs
          |> Enum.into(%{})
          |> Map.put_new(:account, account)
          |> actor_fixture()

        nil ->
          actor_fixture(account: account)
      end

    context_type = Map.get_lazy(attrs, :type, fn -> actor_context_type(actor.type) end)

    context =
      Map.get_lazy(attrs, :context, fn ->
        %Context{
          type: context_type,
          remote_ip: Map.get(attrs, :remote_ip, {100, 64, 0, 1}),
          remote_ip_location_region: Map.get(attrs, :remote_ip_location_region, "US"),
          remote_ip_location_city: Map.get(attrs, :remote_ip_location_city, "San Francisco"),
          remote_ip_location_lat: Map.get(attrs, :remote_ip_location_lat, 37.7749),
          remote_ip_location_lon: Map.get(attrs, :remote_ip_location_lon, -122.4194),
          user_agent: Map.get(attrs, :user_agent, "Mozilla/5.0")
        }
      end)

    # Portal sessions for portal context, client tokens for client, api tokens for api_client
    {expires_at, credential} =
      case context_type do
        :portal ->
          session =
            Map.get_lazy(attrs, :session, fn ->
              session_attrs =
                attrs
                |> Map.take([:expires_at])
                |> Enum.into(%{account: account, actor: actor})

              portal_session_fixture(session_attrs)
            end)

          credential = %Credential{
            type: :portal_session,
            id: session.id,
            auth_provider_id: session.auth_provider_id
          }

          {session.expires_at, credential}

        :client ->
          token =
            Map.get_lazy(attrs, :token, fn ->
              token_attrs =
                attrs
                |> Map.take([:expires_at])
                |> Enum.into(%{account: account, actor: actor})

              client_token_fixture(token_attrs)
            end)

          credential = %Credential{
            type: :client_token,
            id: token.id,
            auth_provider_id: token.auth_provider_id
          }

          {token.expires_at, credential}

        :api_client ->
          token =
            Map.get_lazy(attrs, :token, fn ->
              token_attrs =
                attrs
                |> Map.take([:expires_at, :name])
                |> Enum.into(%{account: account, actor: actor})

              api_token_fixture(token_attrs)
            end)

          credential = %Credential{type: :api_token, id: token.id}

          {token.expires_at, credential}
      end

    %Subject{
      actor: actor,
      account: account,
      expires_at: expires_at,
      context: context,
      credential: credential
    }
  end

  @doc """
  Build an admin auth subject.
  """
  def admin_subject_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{actor: %{type: :account_admin_user}})
    subject_fixture(attrs)
  end

  defp actor_context_type(:service_account), do: :client
  defp actor_context_type(:api_client), do: :api_client
  defp actor_context_type(_), do: :portal

  @doc """
  Build an auth context with sensible defaults.
  """
  def build_context(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {type, attrs} = Map.pop(attrs, :type, :portal)
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
