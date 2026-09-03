defprotocol PortalAPI.JSON.Encoder do
  @moduledoc """
  Turns a struct into the map the REST API sends for it.

  Implementations are derived in the OpenAPI schema module that documents the
  struct, so the fields a response carries are declared next to the spec:

      Protocol.derive(PortalAPI.JSON.Encoder, Portal.Site,
        except: [:account_id, :health_threshold, :managed_by, :inserted_at, :updated_at]
      )

  `only` or `except` picks the Ecto fields copied as they are. Renamed and
  derived fields come from a `mapper`, a capture of a two-arity function that
  receives the struct and the map built so far and returns the keys to add:

      Protocol.derive(PortalAPI.JSON.Encoder, Portal.Group,
        except: [:account_id, :type],
        mapper: &PortalAPI.Schemas.Group.map/2
      )

  A struct with more than one API shape declares each under `shapes`, and the
  caller picks one with `as:`:

      Protocol.derive(PortalAPI.JSON.Encoder, Portal.Device,
        shapes: [
          client: [only: [...], mapper: &PortalAPI.Schemas.Client.map/2],
          gateway: [only: [...], mapper: &PortalAPI.Schemas.Gateway.map/2]
        ]
      )

      PortalAPI.JSON.Encoder.encode(device, as: :gateway)
  """

  @doc "The API representation of `struct`. `opts` may name the shape with `as:`."
  @spec encode(t, keyword()) :: map()
  def encode(struct, opts)

  defmacro __deriving__(module, opts) do
    shapes = PortalAPI.JSON.Encoder.Derived.shapes(module, opts)

    quote do
      defimpl PortalAPI.JSON.Encoder, for: unquote(module) do
        def encode(struct, opts) do
          PortalAPI.JSON.Encoder.Derived.encode(struct, unquote(Macro.escape(shapes)), opts)
        end
      end
    end
  end
end

defmodule PortalAPI.JSON.Encoder.Derived do
  @moduledoc false

  @doc false
  def shapes(module, opts) do
    case Keyword.fetch(opts, :shapes) do
      {:ok, shapes} -> Map.new(shapes, fn {name, shape} -> {name, shape(module, shape)} end)
      :error -> %{default: shape(module, opts)}
    end
  end

  @doc false
  def encode(struct, shapes, opts) do
    name = Keyword.get(opts, :as, :default)

    shape =
      Map.get(shapes, name) ||
        raise ArgumentError,
              "#{inspect(struct.__struct__)} has no #{inspect(name)} shape, " <>
                "known shapes: #{inspect(Map.keys(shapes))}"

    base = Map.take(struct, shape.fields)

    case shape.mapper do
      nil -> base
      mapper -> Map.merge(base, mapper.(struct, base))
    end
  end

  # Fields marked `redact: true` on the Ecto schema never leave the portal,
  # whatever `only` or `except` say.
  defp shape(module, opts) do
    fields =
      (module.__schema__(:fields) ++ module.__schema__(:virtual_fields)) --
        module.__schema__(:redact_fields)

    fields =
      case {Keyword.fetch(opts, :only), Keyword.fetch(opts, :except)} do
        {{:ok, only}, :error} -> assert_fields!(module, only, fields)
        {:error, {:ok, except}} -> fields -- assert_fields!(module, except, fields)
        {:error, :error} -> fields
        _ -> raise ArgumentError, "give either :only or :except, not both"
      end

    %{fields: fields, mapper: Keyword.get(opts, :mapper)}
  end

  defp assert_fields!(module, listed, fields) do
    case listed -- fields do
      [] -> listed
      unknown -> raise ArgumentError, "#{inspect(module)} has no fields #{inspect(unknown)}"
    end
  end
end
