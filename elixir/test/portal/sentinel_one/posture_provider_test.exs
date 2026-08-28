defmodule Portal.SentinelOne.PostureProviderTest do
  use Portal.DataCase, async: true

  alias Portal.SentinelOne.PostureProvider

  test "normalizes a pasted console path to its HTTPS origin" do
    changeset =
      %PostureProvider{}
      |> Ecto.Changeset.cast(
        %{
          management_url: "Tenant-US1.SentinelOne.net/dashboard/agents",
          api_token: String.duplicate("x", 600),
          is_verified: true
        },
        [:management_url, :api_token, :is_verified]
      )
      |> PostureProvider.changeset()

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :management_url) ==
             "https://tenant-us1.sentinelone.net"
  end

  test "rejects a non-SentinelOne management host" do
    changeset =
      %PostureProvider{}
      |> Ecto.Changeset.cast(
        %{management_url: "https://example.com", api_token: "token", is_verified: true},
        [:management_url, :api_token, :is_verified]
      )
      |> PostureProvider.changeset()

    refute changeset.valid?
    assert "must be a SentinelOne management URL, such as https://acme.sentinelone.net" in errors_on(
             changeset
           ).management_url
  end
end
