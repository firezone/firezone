defmodule Credo.Check.Warning.MissingDBAlias do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Modules that have an inline DB module should alias it as `alias __MODULE__.DB`.

      This ensures all database operations go through the module's own DB module
      and makes the code more maintainable and consistent.
      """,
      params: []
    ]

  @doc false
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)

    ast = Credo.Code.ast(source_file)
    modules_info = analyze_modules(ast)

    # Check each top-level module
    modules_info
    |> Enum.filter(fn {_module_name, info} ->
      info.has_db_module and not info.has_db_alias
    end)
    |> Enum.map(fn {module_name, info} ->
      format_issue(
        issue_meta,
        message:
          "Module #{module_name} has a DB submodule but doesn't alias it. Add `alias __MODULE__.DB` to the module.",
        trigger: module_name,
        line_no: info.line_no
      )
    end)
  end

  defp analyze_modules(ast) do
    {_, modules} = Macro.prewalk(ast, %{}, &extract_module_info/2)
    modules
  end

  defp extract_module_info(
         {:defmodule, meta, [{:__aliases__, _, module_parts}, [do: body]]} = ast,
         acc
       ) do
    module_name = Enum.join(module_parts, ".")

    # Check if this module has a DB submodule
    has_db_module = has_inline_db_module?(body)

    # Check if this module has alias __MODULE__.DB
    has_db_alias = has_db_alias?(body)

    info = %{
      has_db_module: has_db_module,
      has_db_alias: has_db_alias,
      line_no: meta[:line]
    }

    {ast, Map.put(acc, module_name, info)}
  end

  defp extract_module_info(ast, acc), do: {ast, acc}

  defp has_inline_db_module?(body) do
    {_, result} =
      Macro.prewalk(body, false, fn
        {:defmodule, _, [{:__aliases__, _, ["DB"]}, _]}, _acc ->
          {:halt, true}

        ast, acc ->
          {ast, acc}
      end)

    result
  end

  defp has_db_alias?(body) do
    {_, result} =
      Macro.prewalk(body, false, fn
        # Check for alias __MODULE__.DB
        {:alias, _, [{:__aliases__, _, [{:__MODULE__, _, _}, "DB"]}]}, _acc ->
          {:halt, true}

        # Check for alias __MODULE__.DB, as: DB
        {:alias, _,
         [{:__aliases__, _, [{:__MODULE__, _, _}, "DB"]}, [as: {:__aliases__, _, ["DB"]}]]},
        _acc ->
          {:halt, true}

        # Also check for the common pattern where __MODULE__ is expanded
        {:alias, _, [{:__aliases__, _, [_, "DB"]}]}, _acc ->
          # This could be a pattern like `alias MyModule.DB` where MyModule is __MODULE__
          # We'll be conservative and consider this as having the alias
          {:halt, true}

        ast, acc ->
          {ast, acc}
      end)

    result
  end
end
