defmodule Domain.Config.Definition do
  @moduledoc """
  This module provides a DSL to define application configuration, which can be read from multiple sources,
  casted and validated.

  ## Examples

    defmodule MyConfig do
      use Domain.Config.Definition

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
  alias Domain.Config.Errors

  @type array_opts :: [{:validate_unique, boolean()} | {:validate_length, Keyword.t()}]

  @type type ::
          Ecto.Type.t()
          | {:embed, Ecto.Schema.t()}
          | {:json_array, type()}
          | {:json_array, type(), array_opts()}
          | {:array, separator :: String.t(), type()}
          | {:array, separator :: String.t(), type(), array_opts()}
          | {:one_of, type()}

  @type legacy_key :: {:env, var_name :: String.t(), removed_at :: String.t()}

  @type changeset_callback ::
          (changeset :: Ecto.Changeset.t(), key :: atom() -> Ecto.Changeset.t())
          | (type :: term(), changeset :: Ecto.Changeset.t(), key :: atom() -> Ecto.Changeset.t())
          | {module(), atom(), [term()]}

  @type dump_callback :: (value :: term() -> term())

  @type opts :: [
          default: term,
          sensitive: boolean(),
          dump: dump_callback(),
          changeset: changeset_callback()
        ]

  defmacro __using__(_opts) do
    quote do
      import Domain.Config.Definition
      import Domain.Config, only: [env_var_to_config!: 1]

      # Accumulator keeps the list of defined config keys
      Module.register_attribute(__MODULE__, :configs, accumulate: true)

      # A `configs/0` function is injected before module is compiled
      # exporting the aggregated list of config keys
      @before_compile Domain.Config.Definition

      @doc "See `Domain.Config.Definition.fetch_doc/2`"
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
      @spec unquote(key)() :: {Domain.Config.Definition.type(), Domain.Config.Definition.opts()}
      def unquote(key)(), do: {unquote(type), unquote(opts)}
    end
  end

  def fetch_spec_and_opts!(module, key) do
    {type, opts} = apply(module, key, [])
    {resolve_opts, opts} = Keyword.split(opts, [:default])
    {validate_opts, opts} = Keyword.split(opts, [:changeset])
    {debug_opts, opts} = Keyword.split(opts, [:sensitive])
    {dump_opts, opts} = Keyword.split(opts, [:dump])

    if opts != [], do: Errors.invalid_spec(key, opts)

    {type, {resolve_opts, validate_opts, dump_opts, debug_opts}}
  end

  def fetch_doc(module) do
    with {:docs_v1, _, _, _, module_doc, _, _function_docs} <- Code.fetch_docs(module) do
      fetch_en_doc(module_doc)
    end
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
