defmodule Portal.Santa.PostureProviderTest do
  use Portal.DataCase, async: true

  alias Portal.Santa.PostureProvider

  test "normalizes a pasted Workshop path to its HTTPS tenant origin" do
    changeset =
      %PostureProvider{}
      |> Ecto.Changeset.cast(
        %{
          api_url: " ACME.Workshop.Cloud/api/explorer ",
          api_key: "npsws_sk_secret",
          is_verified: true
        },
        [:api_url, :api_key, :is_verified]
      )
      |> PostureProvider.changeset()

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :api_url) == "https://acme.workshop.cloud"
  end

  test "rejects non-Workshop endpoints and non-Workshop keys" do
    changeset =
      %PostureProvider{}
      |> Ecto.Changeset.cast(
        %{api_url: "https://127.0.0.1", api_key: "secret", is_verified: true},
        [:api_url, :api_key, :is_verified]
      )
      |> PostureProvider.changeset()

    refute changeset.valid?
    assert "must be a Workshop tenant URL, such as https://acme.workshop.cloud" in errors_on(changeset).api_url
    assert "must be a Workshop API key beginning with npsws_sk_" in errors_on(changeset).api_key
  end
end
