defmodule PortalWeb.AuthenticationTest do
  use PortalWeb.ConnCase, async: true
  import PortalWeb.Authentication

  describe "take_sign_in_params/1" do
    test "takes params used for sign in" do
      for key <- ["as", "state", "nonce", "redirect_to"] do
        assert take_sign_in_params(%{key => "foo"}) == %{key => "foo"}
      end
    end

    test "ignores other params" do
      assert take_sign_in_params(%{"foo" => "bar"}) == %{}
    end

    test "filters out empty string values" do
      assert take_sign_in_params(%{"as" => "", "state" => "foo"}) == %{"state" => "foo"}
    end

    test "filters out nil values" do
      assert take_sign_in_params(%{"as" => nil, "nonce" => "bar"}) == %{"nonce" => "bar"}
    end

    test "handles nil input" do
      assert take_sign_in_params(nil) == %{}
    end
  end
end
