defmodule PortalAPI.JSONTest do
  use ExUnit.Case, async: true

  alias PortalAPI.JSON
  alias PortalAPI.Schemas.Object

  # A stand-in for a view module; only ever appears in error messages.
  @view PortalAPI.SomeJSON

  describe "__verify__!/6" do
    test "passes when every field is exposed or internal" do
      assert :ok =
               JSON.__verify__!(
                 @view,
                 Portal.Entra.Directory,
                 PortalAPI.Schemas.EntraDirectory.Schema,
                 [],
                 [:error_email_count, :is_verified],
                 []
               )
    end

    test "rejects a field that is neither exposed nor internal" do
      assert_raise CompileError, ~r/does not classify every field.*is_verified/s, fn ->
        JSON.__verify__!(
          @view,
          Portal.Entra.Directory,
          PortalAPI.Schemas.EntraDirectory.Schema,
          [],
          [],
          []
        )
      end
    end

    test "rejects a schema field the struct does not have" do
      assert_raise CompileError, ~r/does not have.*tenant_id/s, fn ->
        JSON.__verify__!(
          @view,
          Portal.Site,
          PortalAPI.Schemas.EntraDirectory.Schema,
          [],
          [],
          []
        )
      end
    end

    test "rejects exposing a field that is also marked internal" do
      assert_raise CompileError, ~r/also marked :internal.*tenant_id/s, fn ->
        JSON.__verify__!(
          @view,
          Portal.Entra.Directory,
          PortalAPI.Schemas.EntraDirectory.Schema,
          [],
          [:error_email_count, :is_verified, :tenant_id],
          []
        )
      end
    end

    test "rejects an alias naming a field the struct does not have" do
      assert_raise CompileError, ~r/aliases fields that.*nope/s, fn ->
        JSON.__verify__!(
          @view,
          Portal.Entra.Directory,
          PortalAPI.Schemas.EntraDirectory.Schema,
          [],
          [:error_email_count, :is_verified],
          [tenant_id: :nope]
        )
      end
    end

    test "rejects an alias key the schema does not declare" do
      assert_raise CompileError, ~r/aliases keys the OpenAPI schema does not declare/, fn ->
        JSON.__verify__!(
          @view,
          Portal.Entra.Directory,
          PortalAPI.Schemas.EntraDirectory.Schema,
          [],
          [:error_email_count, :is_verified],
          [not_a_property: :tenant_id]
        )
      end
    end
  end

  describe "assert_classified!/3" do
    test "passes when the allowlist covers every field" do
      fields =
        Portal.Santa.Device.__schema__(:fields) ++ Portal.Santa.Device.__schema__(:virtual_fields)

      assert :ok = Object.assert_classified!(Portal.Santa.Device, fields, [])
    end

    test "rejects an unclassified field" do
      [dropped | rest] = Portal.Santa.Device.__schema__(:fields)

      assert_raise CompileError, ~r/neither exposed nor internal.*#{dropped}/s, fn ->
        Object.assert_classified!(Portal.Santa.Device, rest, [])
      end
    end

    test "accepts a field that is classified as internal" do
      [dropped | rest] = Portal.Santa.Device.__schema__(:fields)
      virtual = Portal.Santa.Device.__schema__(:virtual_fields)

      assert :ok = Object.assert_classified!(Portal.Santa.Device, rest ++ virtual, [dropped])
    end
  end

  describe "render/3" do
    test "raises when a declared field is neither on the struct nor computed" do
      assert_raise ArgumentError, ~r/declares unprovided fields/, fn ->
        JSON.render(%Portal.Site{}, PortalAPI.Schemas.EntraDirectory.Schema)
      end
    end

    test "does not require fields the schema marks optional" do
      resource = %Portal.Resource{ip_stack: nil, site_id: nil, filters: []}

      payload = JSON.render(resource, PortalAPI.Schemas.Resource.Schema, %{filters: []})

      assert Map.has_key?(payload, :ip_stack)
      assert Map.has_key?(payload, :site_id)
    end
  end

  describe "omit_nils/2" do
    test "drops only the named keys whose value is nil" do
      payload = %{a: nil, b: nil, c: 1}

      assert JSON.omit_nils(payload, [:a]) == %{b: nil, c: 1}
    end
  end

  describe "field_names/0" do
    test "matches the schema's declared properties" do
      declared = PortalAPI.Schemas.EntraDirectory.Schema.schema().properties |> Map.keys()

      assert Enum.sort(declared) == PortalAPI.Schemas.EntraDirectory.Schema.field_names()
    end

    test "required mirrors the declared fields minus the optional ones" do
      schema = PortalAPI.Schemas.Resource.Schema.schema()
      optional = PortalAPI.Schemas.Resource.Schema.optional_field_names()

      assert Enum.sort(schema.required) ==
               Enum.sort(PortalAPI.Schemas.Resource.Schema.field_names() -- optional)

      assert optional == [:ip_stack, :site_id]
    end
  end
end
