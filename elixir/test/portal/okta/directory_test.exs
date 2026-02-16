defmodule Portal.Okta.DirectoryTest do
  use Portal.DataCase, async: true

  import Ecto.Changeset
  import Portal.OktaDirectoryFixtures

  alias Portal.Okta.Directory

  defp build_changeset(attrs) do
    %Directory{}
    |> cast(attrs, [:name, :okta_domain, :client_id, :private_key_jwk, :kid, :is_verified])
    |> Directory.changeset()
  end

  describe "changeset/1 basic validations" do
    test "inserts okta_domain at maximum length" do
      dir = okta_directory_fixture(okta_domain: String.duplicate("a", 255))
      assert String.length(dir.okta_domain) == 255
    end

    test "rejects okta_domain exceeding maximum length" do
      changeset = build_changeset(%{okta_domain: String.duplicate("a", 256)})
      assert %{okta_domain: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end

    test "inserts name at maximum length" do
      dir = okta_directory_fixture(name: String.duplicate("a", 255))
      assert String.length(dir.name) == 255
    end

    test "rejects name exceeding maximum length" do
      changeset = build_changeset(%{name: String.duplicate("a", 256)})
      assert %{name: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end
  end
end
