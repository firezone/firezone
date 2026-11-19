defmodule Portal.AccountSlugTest do
  use ExUnit.Case, async: true

  alias Portal.AccountSlug

  describe "possible?/1" do
    test "accepts account IDs, slugs, hyphen twins, and any case" do
      for value <- [Ecto.UUID.generate(), "acme", "acme_corp", "acme-corp", "Acme-Corp", String.duplicate("a", 100)] do
        assert AccountSlug.possible?(value), value
      end
    end

    test "rejects anything else" do
      for value <- ["/.aws/credentials", ".env", "acme corp", "acme__corp", "-acme", "o'brien", "", <<0xFF>>, String.duplicate("a", 101)] do
        refute AccountSlug.possible?(value), inspect(value)
      end
    end
  end
end
