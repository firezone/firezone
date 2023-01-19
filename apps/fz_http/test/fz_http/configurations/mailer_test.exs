defmodule FzHttp.Configurations.MailerTest do
  use ExUnit.Case, async: true

  alias FzHttp.Configurations.Mailer

  describe "changeset/1" do
    test "adds errors for required fields" do
      changeset = Mailer.changeset(%{})

      assert changeset.errors[:from] == {"can't be blank", [validation: :required]}
      assert changeset.errors[:provider] == {"can't be blank", [validation: :required]}
      assert changeset.errors[:configs] == {"can't be blank", [validation: :required]}
    end

    test "adds error for invalid from address" do
      changeset = Mailer.changeset(%{"from" => "invalid"})

      assert changeset.errors[:from] == {"has invalid format", [validation: :format]}
    end

    test "adds error when provider is not in configs" do
      changeset =
        Mailer.changeset(%{"from" => "foobar@localhost", "provider" => "smtp", "configs" => %{}})

      assert changeset.errors[:provider] == {"must exist in configs", []}
    end

    test "doesn't add errors when attrs is valid" do
      changeset =
        Mailer.changeset(%{
          "from" => "foobar@localhost",
          "provider" => "smtp",
          "configs" => %{"smtp" => %{}}
        })

      assert changeset.errors == []
    end
  end
end
