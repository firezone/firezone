defmodule Portal.Sophos.PostureProviderTest do
  use Portal.DataCase, async: true

  alias Portal.Sophos.PostureProvider

  @fields [:client_id, :client_secret, :tenant_id, :data_region_url, :is_verified]

  test "accepts a Sophos regional API host" do
    changeset = changeset(data_region_url: "https://api-eu01.central.sophos.com")

    assert changeset.valid?
  end

  test "rejects a host that is not a Sophos regional API host" do
    for url <- [
          "https://example.com",
          "http://api-eu01.central.sophos.com",
          "https://api-eu01.central.sophos.com.example.com",
          "https://api.central.sophos.com"
        ] do
      refute changeset(data_region_url: url).valid?, url
    end
  end

  defp changeset(overrides) do
    attrs =
      Map.merge(
        %{
          client_id: " client-id ",
          client_secret: "secret",
          tenant_id: Ecto.UUID.generate(),
          data_region_url: "https://api-us03.central.sophos.com",
          is_verified: true
        },
        Map.new(overrides)
      )

    %PostureProvider{}
    |> Ecto.Changeset.cast(attrs, @fields)
    |> PostureProvider.changeset()
  end
end
