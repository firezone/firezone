defmodule Portal.PortalSessionFixtures do
  @moduledoc """
  Test helpers for building portal sessions.
  """

  import Ecto.Changeset
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures

  def valid_portal_session_attrs do
    %{
      user_agent: "Mozilla/5.0",
      remote_ip: %Postgrex.INET{address: {100, 64, 0, 1}},
      remote_ip_location_region: "US",
      remote_ip_location_city: "San Francisco",
      remote_ip_location_lat: 37.7749,
      remote_ip_location_lon: -122.4194,
      expires_at: DateTime.utc_now() |> DateTime.add(86400, :second)
    }
  end

  @doc """
  Build a portal session with sensible defaults.
  """
  def portal_session_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, valid_portal_session_attrs())

    account = Map.get_lazy(attrs, :account, fn -> account_fixture() end)
    actor = Map.get_lazy(attrs, :actor, fn -> actor_fixture(account: account) end)

    auth_provider =
      Map.get_lazy(attrs, :auth_provider, fn ->
        email_otp_provider_fixture(account: account).auth_provider
      end)

    %Portal.PortalSession{}
    |> change(attrs)
    |> put_assoc(:account, account)
    |> put_assoc(:actor, actor)
    |> put_assoc(:auth_provider, auth_provider)
    |> Portal.Repo.insert!()
  end
end
