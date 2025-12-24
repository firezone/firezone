defmodule Portal.MailerTest do
  use ExUnit.Case, async: true
  import Portal.Mailer

  describe "deliver_with_rate_limit/2" do
    test "delivers email with rate limit" do
      email = %Swoosh.Email{to: "foo@bar.com", subject: "Hello"}
      config = [rate_limit: 10, rate_limit_interval: :timer.minutes(2)]

      assert deliver_with_rate_limit(email, config) == {:error, :from_not_set}
    end

    test "does not deliver email when it's rate limited" do
      email = %Swoosh.Email{to: "foo@bar.com", subject: "World"}
      config = [rate_limit: 1, rate_limit_interval: :timer.minutes(2)]

      assert deliver_with_rate_limit(email, config) == {:error, :from_not_set}
      assert deliver_with_rate_limit(email, config) == {:error, :rate_limited}
    end
  end
end
