defmodule FzHttp.ConnectivityCheckServiceTest do
  @moduledoc """
  Tests the ConnectivityCheckService module.
  """
  alias Ecto.Adapters.SQL.Sandbox
  alias FzHttp.{ConnectivityChecks, ConnectivityCheckService, Repo}
  use FzHttp.DataCase, async: true

  describe "post_request/0 valid url" do
    @expected_check %{
      response_code: 200,
      response_headers: %{"content-length" => 9, "date" => "Tue, 07 Dec 2021 19:57:02 GMT"},
      response_body: "127.0.0.1"
    }

    test "inserts connectivity check" do
      ConnectivityCheckService.post_request()
      assert [@expected_check] = ConnectivityChecks.list_connectivity_checks()
    end
  end

  describe "post_request/0 error" do
    @expected_response %{reason: :nxdomain}
    @url "invalid-url"

    @tag capture_log: true
    test "returns error reason" do
      assert @expected_response = ConnectivityCheckService.post_request(@url)
      assert ConnectivityChecks.list_connectivity_checks() == []
    end
  end

  describe "handle_info/2" do
    @expected_response %{
      headers: [
        {"content-length", 9},
        {"date", "Tue, 07 Dec 2021 19:57:02 GMT"}
      ],
      status_code: 200,
      body: "127.0.0.1"
    }

    setup _tags do
      %{test_pid: start_supervised!(ConnectivityCheckService)}
    end

    test ":perform", %{test_pid: test_pid} do
      Sandbox.allow(Repo, self(), test_pid)
      send(test_pid, :perform)
      assert @expected_response == :sys.get_state(test_pid)
    end
  end
end
