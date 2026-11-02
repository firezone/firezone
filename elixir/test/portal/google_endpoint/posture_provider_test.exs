defmodule Portal.GoogleEndpoint.PostureProviderTest do
  use Portal.DataCase, async: true

  import Portal.GoogleEndpointFixtures

  alias Portal.GoogleEndpoint.PostureProvider

  test "requires the impersonated administrator and domain" do
    changeset =
      %PostureProvider{}
      |> Ecto.Changeset.cast(%{is_verified: true}, [:is_verified])
      |> PostureProvider.changeset()

    assert %{impersonation_email: ["can't be blank"], domain: ["can't be blank"]} =
             errors_on(changeset)
  end

  test "connects a Workspace to an account only once" do
    provider = google_endpoint_posture_provider_fixture(domain: "acme.com")

    assert_raise Ecto.InvalidChangesetError, ~r/already connected/, fn ->
      google_endpoint_posture_provider_fixture(
        account: Repo.get!(Portal.Account, provider.account_id),
        domain: "acme.com"
      )
    end
  end
end
