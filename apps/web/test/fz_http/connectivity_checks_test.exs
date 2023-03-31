defmodule FzHttp.ConnectivityChecksTest do
  use FzHttp.DataCase, async: true
  alias FzHttp.SubjectFixtures
  alias FzHttp.ConnectivityChecksFixtures
  alias FzHttp.ConnectivityChecks
  import FzHttp.ConnectivityChecks

  setup do
    subject = SubjectFixtures.create_subject()

    %{subject: subject}
  end

  describe "list_connectivity_checks/1" do
    test "returns empty list when no connectivity_checks", %{subject: subject} do
      assert list_connectivity_checks(subject) == []
    end

    test "list_connectivity_checks/0 returns up to 100 connectivity_checks", %{subject: subject} do
      for _ <- 1..101 do
        ConnectivityChecksFixtures.create_connectivity_check()
      end

      assert length(list_connectivity_checks(subject)) == 100
    end

    test "list_connectivity_checks/1 allows to change the limit", %{subject: subject} do
      ConnectivityChecksFixtures.create_connectivity_check()
      connectivity_check = ConnectivityChecksFixtures.create_connectivity_check()
      assert list_connectivity_checks(subject, limit: 1) == [connectivity_check]
    end

    test "returns error when subject has no permission", %{subject: subject} do
      subject = SubjectFixtures.remove_permissions(subject)

      assert list_connectivity_checks(subject) ==
               {:error,
                {:unauthorized,
                 [
                   missing_permissions: [
                     ConnectivityChecks.Authorizer.view_connectivity_checks_permission()
                   ]
                 ]}}
    end
  end

  describe "check_connectivity/1" do
    test "creates a connectivity check if request is successful" do
      bypass = Bypass.open()

      Bypass.expect(bypass, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("foo", "bar")
        |> Plug.Conn.resp(200, "X")
      end)

      request = Finch.build(:post, "http://localhost:#{bypass.port}/")

      assert {:ok, connectivity_check} = check_connectivity(request)
      assert connectivity_check.response_code == 200
      assert connectivity_check.response_body == "X"
      assert %{"foo" => "bar"} = connectivity_check.response_headers

      assert Repo.one(ConnectivityChecks.ConnectivityCheck)
    end

    test "returns error when request fails" do
      bypass = Bypass.open()
      Bypass.down(bypass)

      request = Finch.build(:post, "http://localhost:#{bypass.port}/")

      assert {:error, reason} = check_connectivity(request)
      assert reason == %Mint.TransportError{reason: :econnrefused}
      refute Repo.one(ConnectivityChecks.ConnectivityCheck)
    end
  end
end
