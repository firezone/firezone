defmodule Portal.EmailTest do
  use ExUnit.Case, async: true

  alias Portal.Email

  describe "normalize/1" do
    test "trims components, preserves local-part case, and IDNA-encodes the domain" do
      assert Email.normalize("  User @ BÜCHER.example  ") ==
               {:ok, "User@xn--bcher-kva.example"}
    end

    test "trims input without an at sign for validation by the caller" do
      assert Email.normalize("  invalid  ") == {:ok, "invalid"}
    end

    test "rejects a domain IDNA cannot encode" do
      assert Email.normalize("Ï@ú1å?") == :error
      assert Email.normalize_for_match("Ï@ú1å?") == :error
    end
  end

  describe "normalize_for_match/1" do
    test "normalizes the complete address for case-insensitive matching" do
      assert Email.normalize_for_match("  USER@BÜCHER.example  ") ==
               {:ok, "user@xn--bcher-kva.example"}
    end
  end
end
