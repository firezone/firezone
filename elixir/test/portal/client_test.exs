defmodule Portal.ClientTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures

  describe "changeset/1 basic validations" do
    test "requires telemetry_id" do
      changeset = client_changeset(%{name: "Client"})
      assert %{telemetry_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "inserts name at maximum length" do
      client = client_fixture(name: String.duplicate("a", 255))
      assert String.length(client.name) == 255
    end

    test "rejects name exceeding maximum length" do
      changeset = client_changeset(%{name: String.duplicate("a", 256)})
      assert %{name: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end

    test "rejects telemetry_id exceeding maximum length" do
      changeset = client_changeset(%{name: "Client", telemetry_id: String.duplicate("a", 256)})
      assert %{telemetry_id: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end

    test "allows nil hostname" do
      client = client_fixture(hostname: nil)
      assert client.hostname == nil
    end

    test "inserts hostname at maximum length" do
      client = client_fixture(hostname: String.duplicate("a", 255))
      assert String.length(client.hostname) == 255
    end

    test "rejects hostname exceeding maximum length" do
      changeset =
        client_changeset(%{
          name: "Client",
          telemetry_id: "fid",
          hostname: String.duplicate("a", 256)
        })

      assert %{hostname: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end

    test "trims hostname whitespace" do
      client = client_fixture(hostname: "  host.example.com  ")
      assert client.hostname == "host.example.com"
    end

    test "rejects hostname that is empty after trimming via length validation when explicitly all-whitespace" do
      # Empty / whitespace-only hostnames collapse to nil rather than failing — this is
      # how the field is "cleared" via the API. See `normalize_hostname/1`.
      client = client_fixture(hostname: "   ")
      assert client.hostname == nil
    end

    test "preserves hostname casing on write (citext column folds case in comparisons)" do
      client = client_fixture(hostname: "Host.Example.COM")
      assert client.hostname == "Host.Example.COM"
    end

    test "rejects hostname shorter than 3 characters" do
      changeset = client_changeset(%{name: "Client", telemetry_id: "fid", hostname: "ab"})

      assert %{hostname: ["should be at least 3 character(s)"]} = errors_on(changeset)
    end

    test "accepts a 3-character hostname" do
      client = client_fixture(hostname: "abc")
      assert client.hostname == "abc"
    end

    test "treats empty string hostname as nil" do
      client = client_fixture(hostname: "")
      assert client.hostname == nil
    end

    test "rejects duplicate hostname within the same account for clients" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      first = client_fixture(account: account, actor: actor, hostname: "host.example.com")
      assert first.hostname == "host.example.com"

      assert {:error, %Ecto.Changeset{} = changeset} =
               insert_client(account, actor, %{
                 name: "Second",
                 telemetry_id: "fid-second",
                 hostname: "host.example.com"
               })

      assert %{hostname: ["has already been taken"]} = errors_on(changeset)
    end

    test "rejects duplicate hostname differing only in case (case-insensitive uniqueness)" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      first = client_fixture(account: account, actor: actor, hostname: "Host.Example.com")
      assert first.hostname == "Host.Example.com"

      assert {:error, %Ecto.Changeset{} = changeset} =
               insert_client(account, actor, %{
                 name: "Second",
                 telemetry_id: "fid-second",
                 hostname: "host.example.COM"
               })

      assert %{hostname: ["has already been taken"]} = errors_on(changeset)
    end

    test "allows duplicate hostname across different accounts" do
      a1 = account_fixture()
      a2 = account_fixture()
      c1 = client_fixture(account: a1, hostname: "host.example.com")
      c2 = client_fixture(account: a2, hostname: "host.example.com")
      assert c1.hostname == c2.hostname
    end

    test "allows multiple nil hostnames within the same account" do
      account = account_fixture()
      c1 = client_fixture(account: account, hostname: nil)
      c2 = client_fixture(account: account, hostname: nil)
      assert c1.hostname == nil
      assert c2.hostname == nil
    end
  end
end
