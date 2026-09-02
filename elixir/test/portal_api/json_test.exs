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

  describe "Subject schemas track Authentication.Subject" do
    # PortalAPI.Schemas.Subject documents what Authentication.Subject.to_map/1
    # emits. Nothing links them, so a field added to to_map/1 would silently go
    # undocumented -- which is how ClientSessionSubject came to omit device_id
    # and token_id in the first place.
    setup do
      schemas = PortalAPI.ApiSpec.spec() |> OpenApiSpex.resolve_schema_modules() |> Map.get(:components) |> Map.get(:schemas)
      # Built in memory rather than from a fixture: this asserts on the shape
      # to_map/1 produces, which needs no database.
      subject = %Portal.Authentication.Subject{
        account: %Portal.Account{id: Ecto.UUID.generate()},
        actor: %Portal.Actor{
          id: Ecto.UUID.generate(),
          name: "Admin User",
          email: "admin@example.com",
          type: :account_admin_user
        },
        credential: %Portal.Authentication.Credential.ClientToken{
          id: Ecto.UUID.generate(),
          auth_provider_id: Ecto.UUID.generate()
        },
        expires_at: DateTime.utc_now(),
        context: %Portal.Authentication.Context{
          type: :client,
          remote_ip: {100, 64, 0, 1},
          remote_ip_location_region: "US",
          remote_ip_location_city: "San Francisco",
          remote_ip_location_lat: 37.7749,
          remote_ip_location_lon: -122.4194,
          user_agent: "iOS/12.5 (iPhone) connlib/0.7.412"
        }
      }

      emitted = subject |> Portal.Authentication.Subject.to_map() |> Map.keys()

      %{schemas: schemas, emitted: MapSet.new(emitted, &to_string/1)}
    end

    test "Subject documents exactly what to_map/1 emits", %{schemas: schemas, emitted: emitted} do
      documented = schemas["Subject"].properties |> Map.keys() |> MapSet.new(&to_string/1)

      assert documented == emitted,
             """
             PortalAPI.Schemas.Subject is out of sync with
             Authentication.Subject.to_map/1.

               undocumented: #{inspect(Enum.sort(MapSet.difference(emitted, documented)))}
               never emitted: #{inspect(Enum.sort(MapSet.difference(documented, emitted)))}
             """
    end

    test "ClientSessionSubject is Subject plus the Client and token", %{
      schemas: schemas,
      emitted: emitted
    } do
      # PortalAPI.Client.Socket merges these two into the subject it logs.
      expected = MapSet.union(emitted, MapSet.new(["device_id", "token_id"]))
      documented = schemas["ClientSessionSubject"].properties |> Map.keys() |> MapSet.new(&to_string/1)

      assert documented == expected,
             """
             ClientSessionSubject no longer matches Authentication.Subject.to_map/1
             plus the keys PortalAPI.Client.Socket merges in.

               undocumented: #{inspect(Enum.sort(MapSet.difference(expected, documented)))}
               never emitted: #{inspect(Enum.sort(MapSet.difference(documented, expected)))}
             """
    end
  end

  describe "OpenAPI examples" do
    # Schemas whose payload is legitimately partial. A PATCH or POST body names
    # only the fields being sent, so an example covering every property would
    # misrepresent it.
    @partial_examples ["PolicyCreateParams", "PolicyUpdateParams"]

@known_bad []

    setup do
      spec = PortalAPI.ApiSpec.spec() |> OpenApiSpex.resolve_schema_modules()
      %{schemas: spec.components.schemas}
    end

    test "no two schema modules share an OpenAPI title" do
      # OpenApiSpex keys components.schemas by title, so two modules with the
      # same title silently collapse into one and every $ref to that title
      # resolves to whichever won. That once pointed GET /client_tokens/{id} at
      # a payload containing the token secret. The components map is already
      # keyed by title, so this has to enumerate the modules themselves.
      {:ok, modules} = :application.get_key(:portal, :modules)

      by_title =
        modules
        |> Enum.filter(&(&1 |> Atom.to_string() |> String.starts_with?("Elixir.PortalAPI.Schemas.")))
        |> Enum.filter(&function_exported?(&1, :schema, 0))
        |> Enum.group_by(& &1.schema().title)
        |> Enum.reject(fn {title, mods} -> is_nil(title) or length(mods) == 1 end)

      assert by_title == [],
             """
             These OpenAPI titles are declared by more than one schema module.
             Only one survives in components.schemas, so any $ref to the title
             may resolve to the wrong schema:

             #{Enum.map_join(by_title, "\n", fn {title, mods} -> "  #{title}: #{inspect(mods)}" end)}
             """
    end

    test "every example covers all of its schema's properties", %{schemas: schemas} do
      assert audit(schemas, :missing) == [],
             """
             These examples omit properties, so Swagger UI renders an incomplete
             sample. Note that an example on a wrapper schema overrides the one
             composed from its members, so a partial `data` object hides every
             field the member schema documents.

             #{format(audit(schemas, :missing))}

             Either cover every property, or drop the `example:` and let it be
             derived from the schema.
             """
    end

    test "no example names a property its schema does not declare", %{schemas: schemas} do
      assert audit(schemas, :unknown) == [],
             """
             These examples name keys that are not properties of their schema,
             which usually means a typo or a renamed field:

             #{format(audit(schemas, :unknown))}
             """
    end

    # Walks each schema's example against the schema, descending through
    # properties that reference another schema so a nested object is checked
    # against the schema it claims to be an example of.
    defp audit(schemas, kind) do
      for {name, schema} <- schemas,
          name not in @known_bad,
          is_map(schema.example),
          {path, keys} <- compare(schemas, schema, schema.example, name, kind),
          do: {path, keys}
    end

    defp compare(schemas, schema, example, path, kind) do
      props = schema.properties

      if is_map(props) and is_map(example) do
        here =
          case kind do
            :missing -> keys(props) |> MapSet.difference(keys(example))
            :unknown -> keys(example) |> MapSet.difference(keys(props))
          end

        here =
          if MapSet.size(here) > 0 and not exempt?(path), do: [{path, Enum.sort(here)}], else: []

        here ++ descend(schemas, props, example, path, kind)
      else
        []
      end
    end

    defp descend(schemas, props, example, path, kind) do
      Enum.flat_map(example, fn {key, value} ->
        prop = Map.get(props, to_atom(key))

        case {variants(prop), nested_example(value)} do
          {[], _} -> []
          {_, []} -> []
          {targets, [inner]} -> check_variants(schemas, targets, inner, "#{path}.#{key}", kind)
        end
      end)
    end

    # A `oneOf` example only has to satisfy one variant. Report against every
    # variant only when it satisfies none of them, so the message shows what it
    # would have taken to match.
    defp check_variants(schemas, targets, inner, path, kind) do
      results =
        for target <- targets,
            nested = schemas[target],
            not is_nil(nested),
            do: {target, compare(schemas, nested, inner, "#{path} -> #{target}", kind)}

      cond do
        results == [] -> []
        Enum.any?(results, fn {_target, findings} -> findings == [] end) -> []
        match?([_], results) -> results |> hd() |> elem(1)
        true -> [{path, ["matches none of #{Enum.map_join(results, ", ", &elem(&1, 0))}"]}]
      end
    end

    defp variants(%OpenApiSpex.Reference{"$ref": ref}), do: [List.last(String.split(ref, "/"))]
    defp variants(%OpenApiSpex.Schema{oneOf: [_ | _] = one_of}), do: Enum.flat_map(one_of, &variants/1)
    defp variants(%OpenApiSpex.Schema{type: :array, items: items}), do: variants(items)
    defp variants(_), do: []

    defp nested_example(value) when is_map(value), do: [value]
    defp nested_example([head | _]) when is_map(head), do: [head]
    defp nested_example(_), do: []

    defp exempt?(path), do: Enum.any?(@partial_examples, &String.contains?(path, &1))

    defp to_atom(key) when is_atom(key), do: key

    defp to_atom(key) when is_binary(key) do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> :__unknown__
    end

    defp keys(map), do: map |> Map.keys() |> Enum.map(&to_string/1) |> MapSet.new()

    defp format(entries),
      do: Enum.map_join(entries, "\n", fn {path, keys} -> "  #{path}: #{inspect(keys)}" end)
  end
end
