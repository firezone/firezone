defmodule FzHttp.ConnectivityChecksTest do
  use FzHttp.DataCase, async: true

  alias FzHttp.ConnectivityChecks

  describe "connectivity_checks" do
    alias FzHttp.ConnectivityChecks.ConnectivityCheck

    import FzHttp.ConnectivityChecksFixtures

    @invalid_attrs %{response_body: nil, response_code: nil, response_headers: nil, url: nil}

    test "list_connectivity_checks/0 returns all connectivity_checks" do
      connectivity_check = connectivity_check_fixture()
      assert ConnectivityChecks.list_connectivity_checks() == [connectivity_check]
    end

    test "list_connectivity_checks/1 applies limit" do
      connectivity_check_fixture()
      connectivity_check = connectivity_check_fixture()
      assert ConnectivityChecks.list_connectivity_checks(limit: 1) == [connectivity_check]
    end

    test "host/0 returns latest check's response body" do
      connectivity_check = connectivity_check_fixture()
      assert ConnectivityChecks.host() == connectivity_check.response_body
    end

    test "get_connectivity_check!/1 returns the connectivity_check with given id" do
      connectivity_check = connectivity_check_fixture()

      assert ConnectivityChecks.get_connectivity_check!(connectivity_check.id) ==
               connectivity_check
    end

    test "create_connectivity_check/1 with valid data creates a connectivity_check" do
      valid_attrs = %{
        response_body: "some response_body",
        response_code: 500,
        response_headers: %{"updated_response" => "headers"},
        url: "https://ping-dev.firez.one/1.1.1"
      }

      assert {:ok, %ConnectivityCheck{} = connectivity_check} =
               ConnectivityChecks.create_connectivity_check(valid_attrs)

      assert connectivity_check.response_body == "some response_body"
      assert connectivity_check.response_code == 500
      assert connectivity_check.response_headers == %{"updated_response" => "headers"}
      assert connectivity_check.url == "https://ping-dev.firez.one/1.1.1"
    end

    test "create_connectivity_check/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} =
               ConnectivityChecks.create_connectivity_check(@invalid_attrs)
    end

    test "update_connectivity_check/2 with valid data updates the connectivity_check" do
      connectivity_check = connectivity_check_fixture()

      update_attrs = %{
        response_body: "some updated response_body",
        response_code: 500,
        response_headers: %{"updated" => "response headers"},
        url: "https://ping-dev.firez.one/6.6.6"
      }

      assert {:ok, %ConnectivityCheck{} = connectivity_check} =
               ConnectivityChecks.update_connectivity_check(connectivity_check, update_attrs)

      assert connectivity_check.response_body == "some updated response_body"
      assert connectivity_check.response_code == 500
      assert connectivity_check.response_headers == %{"updated" => "response headers"}
      assert connectivity_check.url == "https://ping-dev.firez.one/6.6.6"
    end

    test "update_connectivity_check/2 with invalid data returns error changeset" do
      connectivity_check = connectivity_check_fixture()

      assert {:error, %Ecto.Changeset{}} =
               ConnectivityChecks.update_connectivity_check(connectivity_check, @invalid_attrs)

      assert connectivity_check ==
               ConnectivityChecks.get_connectivity_check!(connectivity_check.id)
    end

    test "delete_connectivity_check/1 deletes the connectivity_check" do
      connectivity_check = connectivity_check_fixture()

      assert {:ok, %ConnectivityCheck{}} =
               ConnectivityChecks.delete_connectivity_check(connectivity_check)

      assert_raise Ecto.NoResultsError, fn ->
        ConnectivityChecks.get_connectivity_check!(connectivity_check.id)
      end
    end

    test "change_connectivity_check/1 returns a connectivity_check changeset" do
      connectivity_check = connectivity_check_fixture()
      assert %Ecto.Changeset{} = ConnectivityChecks.change_connectivity_check(connectivity_check)
    end
  end
end
