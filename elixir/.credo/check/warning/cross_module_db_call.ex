defmodule Credo.Check.Warning.CrossModuleDBCall do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Modules should not directly call into other modules' Database submodules.

      Each module should only call its own Database module functions. If you need
      to access data from another module, create a public function in that
      module that delegates to its Database module internally.
      """,
      params: []
    ]

  @doc false
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)

    # Extract the current module name and aliases from the file
    {current_modules, aliases} = extract_module_info(source_file)

    # Find all cross-module Database calls
    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta, current_modules, aliases), [])
  end

  defp extract_module_info(source_file) do
    Credo.Code.prewalk(source_file, &extract_info/2, {[], %{}})
  end

  # Extract module definitions
  defp extract_info(
         {:defmodule, _, [{:__aliases__, _, module_parts}, _]} = ast,
         {modules, aliases}
       )
       when is_list(module_parts) do
    module_name = Enum.map_join(module_parts, ".", &to_string/1)
    {ast, {[module_name | modules], aliases}}
  end

  # Extract alias with :as option - alias Foo.Bar.Database, as: SomeDatabase
  defp extract_info(
         {:alias, _, [{:__aliases__, _, module_parts}, [as: {:__aliases__, _, [alias_name]}]]} =
           ast,
         {modules, aliases}
       )
       when is_list(module_parts) do
    full_module = Enum.map_join(module_parts, ".", &to_string/1)
    alias_key = to_string(alias_name)
    {ast, {modules, Map.put(aliases, alias_key, full_module)}}
  end

  # Extract simple alias - alias Foo.Bar.Baz (aliases to Baz)
  # But not multi-alias or __MODULE__ patterns
  defp extract_info(
         {:alias, _, [{:__aliases__, _, module_parts}]} = ast,
         {modules, aliases}
       )
       when is_list(module_parts) do
    # Skip if contains __MODULE__ tuple
    if Enum.all?(module_parts, &is_atom/1) do
      full_module = Enum.join(module_parts, ".")
      alias_key = to_string(List.last(module_parts))
      {ast, {modules, Map.put(aliases, alias_key, full_module)}}
    else
      {ast, {modules, aliases}}
    end
  end

  # Catch-all for other alias patterns (multi-alias, __MODULE__, etc)
  defp extract_info({:alias, _, _} = ast, acc) do
    {ast, acc}
  end

  defp extract_info(ast, acc) do
    {ast, acc}
  end

  # Check for calls like OtherModule.Database.function() or AliasedDatabase.function()
  defp traverse(
         {{:., meta, [{:__aliases__, _, module_path}, _func]}, _, _} = ast,
         issues,
         issue_meta,
         current_modules,
         aliases
       )
       when is_list(module_path) do
    # Skip if module_path contains non-atoms (like __MODULE__ tuples)
    if Enum.all?(module_path, &is_atom/1) do
      # Resolve aliases in the module path
      resolved_path = resolve_aliases(module_path, aliases)

      if cross_module_db_call?(resolved_path, current_modules) do
        module_name = Enum.join(resolved_path, ".")
        issue = issue_for(meta[:line], issue_meta, module_name)
        {ast, [issue | issues]}
      else
        {ast, issues}
      end
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta, _current_modules, _aliases) do
    {ast, issues}
  end

  defp resolve_aliases(module_path, aliases) do
    case module_path do
      [first | rest] ->
        first_str = to_string(first)

        case Map.get(aliases, first_str) do
          nil ->
            # No alias found, keep as is
            Enum.map(module_path, &to_string/1)

          full_module ->
            # Replace with the full module path
            String.split(full_module, ".") ++ Enum.map(rest, &to_string/1)
        end

      [] ->
        []
    end
  end

  defp cross_module_db_call?(module_path, current_modules) do
    # Check if this is a Database module call
    case List.last(module_path) do
      "Database" when length(module_path) >= 2 ->
        # Get the parent module (everything except "Database")
        parent_parts = Enum.take(module_path, length(module_path) - 1)
        parent_module = Enum.join(parent_parts, ".")

        # It's a cross-module call if the parent module is not in our current modules
        # and it's not a special allowed module
        not Enum.member?(current_modules, parent_module) and
          not Enum.member?(current_modules, parent_module <> ".Database") and
          not allowed_module?(parent_module)

      _ ->
        false
    end
  end

  # Allow certain system modules
  defp allowed_module?("Portal"), do: true
  defp allowed_module?("Portal.Safe"), do: true
  defp allowed_module?(_), do: false

  defp issue_for(line_no, issue_meta, module_name) do
    format_issue(
      issue_meta,
      message:
        "Cross-module Database call detected: #{module_name}. Modules should not call other modules' Database functions directly. Create a public API function instead.",
      trigger: module_name,
      line_no: line_no
    )
  end
end
