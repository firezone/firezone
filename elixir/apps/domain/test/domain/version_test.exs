defmodule Domain.VersionTest do
  use Domain.DataCase, async: true
  import Domain.Version

  describe "fetch_version/1" do
    test "returns connlib version when user agent contains URI-encoded chars" do
      user_agent = "connlib%2F1.2.3%20with%20spaces"
      assert fetch_version(user_agent) == {:ok, "1.2.3"}
    end

    test "returns connlib version when user agent contains UTF-8 characters" do
      user_agent = "connlib%2F1.2.3%205.4.292-Paimon-君の名は。/18a0a2d5"
      assert fetch_version(user_agent) == {:ok, "1.2.3"}
    end

    test "returns connlib version when user agent contains no percent-encoding" do
      user_agent = "connlib/1.2.3 with spaces"
      assert fetch_version(user_agent) == {:ok, "1.2.3"}
    end
  end
end
