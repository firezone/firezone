defmodule FgHttp.Factory do
  @moduledoc """
  Fixtures generator
  """
  use ExMachina.Ecto, repo: FgHttp.Repo

  alias FgHttp.{Devices.Device, Rules.Rule, Users.User}

  def user_factory do
    %User{
      email: "factory@factory",
      password: "factory",
      password_confirmation: "factory"
    }
  end

  def device_factory do
    %Device{
      user: build(:user),
      name: "Factory Device",
      public_key: "factory public key",
      last_ip: %Postgrex.INET{address: {127, 0, 0, 1}}
    }
  end

  def rule_factory do
    %Rule{
      device: build(:device),
      destination: %Postgrex.INET{address: {0, 0, 0, 0}, netmask: 0}
    }
  end
end
