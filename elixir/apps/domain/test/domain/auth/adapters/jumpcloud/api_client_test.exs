defmodule Domain.Auth.Adapters.JumpCloud.APIClientTest do
  use ExUnit.Case, async: true
  alias Domain.Fixtures
  alias Domain.Mocks.WorkOSDirectory
  import Domain.Auth.Adapters.JumpCloud.APIClient

  describe "list_users/1" do
    test "returns list of users" do
      bypass = Bypass.open()
      WorkOSDirectory.override_base_url("http://localhost:#{bypass.port}")

      WorkOSDirectory.mock_list_users_endpoint(bypass)

      directory = Fixtures.WorkOS.create_directory()

      assert {:ok, users} = list_users(directory)

      assert length(users) == 1

      for user <- users do
        assert Map.has_key?(user, :id)
        assert Map.has_key?(user, :idp_id)

        # Profile fields
        assert Map.has_key?(user, :groups)
        assert Map.has_key?(user, :first_name)
        assert Map.has_key?(user, :last_name)
        assert Map.has_key?(user, :state)
        assert Map.has_key?(user, :username)
        assert Map.has_key?(user, :emails)
      end
    end

    test "returns error when WorkOS API is down" do
      bypass = Bypass.open()
      WorkOSDirectory.override_base_url("http://localhost:#{bypass.port}")
      Bypass.down(bypass)

      directory = Fixtures.WorkOS.create_directory()
      assert list_users(directory) == {:error, :client_error}
    end
  end

  describe "list_groups/1" do
    test "returns list of groups" do
      bypass = Bypass.open()
      WorkOSDirectory.override_base_url("http://localhost:#{bypass.port}")

      WorkOSDirectory.mock_list_groups_endpoint(bypass)

      # Mocks.WorkOSDirectory.list_groups()

      directory = Fixtures.WorkOS.create_directory()

      assert {:ok, groups} = list_groups(directory)

      assert length(groups) == 1

      for group <- groups do
        assert Map.has_key?(group, :id)
        assert Map.has_key?(group, :idp_id)
        assert Map.has_key?(group, :name)
        assert Map.has_key?(group, :organization_id)
        assert Map.has_key?(group, :directory_id)
      end
    end

    test "returns error when WorkOS API is down" do
      bypass = Bypass.open()
      WorkOSDirectory.override_base_url("http://localhost:#{bypass.port}")
      Bypass.down(bypass)

      directory = Fixtures.WorkOS.create_directory()

      assert list_groups(directory) == {:error, :client_error}
    end
  end
end
