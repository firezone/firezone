defmodule Domain.GatewaysFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Domain.Gateways` context.
  """
  alias Domain.Gateways
  alias Domain.UsersFixtures
  alias Domain.SubjectFixtures

  def group_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      name_prefix: "group-#{counter()}",
      tags: ["aws", "aws-us-east-#{counter()}"],
      tokens: [%{}]
    })
  end

  def create_group(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {subject, attrs} =
      Map.pop_lazy(attrs, :subject, fn ->
        UsersFixtures.create_user_with_role(:admin)
        |> SubjectFixtures.create_subject()
      end)

    attrs = group_attrs(attrs)

    {:ok, group} = Gateways.create_group(attrs, subject)
    group
  end

  def delete_group(group) do
    admin = UsersFixtures.create_user_with_role(:admin)
    subject = SubjectFixtures.create_subject(admin)
    {:ok, group} = Gateways.delete_group(group, subject)
    group
  end

  def create_token(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    {group_attrs, _attrs} = Map.pop(attrs, :group, [])
    group = create_group(group_attrs)
    hd(group.tokens)
  end

  def gateway_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      external_id: Ecto.UUID.generate(),
      name_suffix: "gw-#{Domain.Crypto.rand_string(5)}",
      public_key: public_key(),
      tokens: [%{}]
    })
  end

  def create_gateway(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {group_attrs, _attrs} = Map.pop(attrs, :group, [])

    {group, attrs} =
      Map.pop_lazy(attrs, :group, fn ->
        create_group(group_attrs)
      end)

    {token, attrs} =
      Map.pop_lazy(attrs, :token, fn ->
        hd(group.tokens)
      end)

    {subject, attrs} =
      Map.pop_lazy(attrs, :subject, fn ->
        UsersFixtures.create_user_with_role(:admin)
        |> SubjectFixtures.create_subject()
      end)

    attrs = gateway_attrs(attrs)

    {:ok, gateway} = Gateways.upsert_gateway(token, attrs, subject)
    gateway
  end

  def delete_gateway(gateway) do
    admin = UsersFixtures.create_user_with_role(:admin)
    subject = SubjectFixtures.create_subject(admin)
    {:ok, gateway} = Gateways.delete_gateway(gateway, subject)
    gateway
  end

  def public_key do
    :crypto.strong_rand_bytes(32)
    |> Base.encode64()
  end

  defp counter do
    System.unique_integer([:positive])
  end
end
