defmodule FzHttp.Config.Definition do
  @moduledoc """
  This module provides a DSL to define application configuration, which can be read from multiple sources,
  casted and validated.

  ## Examples

    defmodule MyConfig do
      use FzHttp.Config.Definition

      @doc "My config key"
      defconfig :my_key, :string, required: true
    end

    iex> MyConfig.my_key()
    {:string, [required: true]}

    iex> MyConfig.configs()
    [:my_key]

    iex> MyConfig.fetch_doc(:my_key)
    {:ok, "My config key"}
  """
  alias FzHttp.Config.Errors

  defmacro __using__(_opts) do
    quote do
      import FzHttp.Config.Definition
      import FzHttp.Config, only: [compile_config!: 1]

      # Accumulator keeps the list of defined config keys
      Module.register_attribute(__MODULE__, :configs, accumulate: true)

      # A `configs/0` function is injected before module is compiled
      # exporting the aggregated list of config keys
      @before_compile FzHttp.Config.Definition

      @doc "See `FzHttp.Config.Definition.fetch_doc/2`"
      def fetch_doc(key), do: fetch_doc(__MODULE__, key)
    end
  end

  @doc """
  Simply exposes the `@configs` attribute as a function after all the `defconfig`'s are compiled.
  """
  defmacro __before_compile__(_env) do
    quote do
      def configs, do: @configs
    end
  end

  @doc """
  Defines a configuration key.

  Behind the hood it defines a function that returns a tuple with the type and options, a function is used
  to allow for `@doc` blocks with markdown to be used to document the configuration key.

  ## Type

  The type can be one of the following:

    * any of the primitive types supported by `Ecto.Schema`;
    * a module that implements Ecto.Type behaviour;
    * `{:array, binary_separator, type}` - a list of values of the given type, separated by the given separator.
    Separator is only used when reading the value from the environment variable or other binary storages;
    * `{:one_of, [type]}` - a value of one of the given types.
  """
  defmacro defconfig(key, type, opts \\ []) do
    quote do
      @configs {__MODULE__, unquote(key)}
      def unquote(key)(), do: {unquote(type), unquote(opts)}
    end
  end

  def fetch_spec_and_opts!(module, key) do
    {type, opts} = apply(module, key, [])
    {resolve_opts, opts} = Keyword.split(opts, [:legacy_keys, :default])
    {validate_opts, opts} = Keyword.split(opts, [:changeset])

    if opts != [], do: Errors.invalid_spec(key, opts)

    {type, {resolve_opts, validate_opts}}
  end

  @doc """
  Returns EN documentation chunk of a given function in a module.
  """
  def fetch_doc(module, key) do
    with {:docs_v1, _, _, _, _module_doc, _, function_docs} <- Code.fetch_docs(module) do
      function_docs
      |> fetch_function_docs(key)
      |> fetch_en_doc()
    end
  end

  defp fetch_function_docs(function_docs, function) do
    function_docs
    |> Enum.find_value(fn
      {{:function, ^function, _}, _, _, doc, _} -> doc
      _other -> nil
    end)
  end

  defp fetch_en_doc(md) when is_map(md), do: Map.fetch(md, "en")
  defp fetch_en_doc(_md), do: :error
end
