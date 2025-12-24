defmodule Credo.Check.Warning.SafeCallsOutsideDBModule do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Portal.Safe should only be called from within a DB module.

      All modules that need to access Portal.Safe should define an inline DB module
      and make all Portal.Safe calls from within that module.
      """,
      params: []
    ]

  @doc false
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)

    # Skip checking the Portal.Safe module itself
    if String.ends_with?(source_file.filename, "domain/lib/domain/safe.ex") do
      []
    else
      source_file
      |> Credo.Code.prewalk(&traverse(&1, &2, issue_meta, []), {[], []})
      |> elem(0)
    end
  end

  # Track when we enter/exit module definitions - maintain a stack of module names
  defp traverse({:defmodule, _meta, [{:__aliases__, _, module_parts}, _]} = ast, {issues, module_stack}, _issue_meta, _parent_modules) do
    module_name = Enum.map_join(module_parts, ".", &to_string/1)
    new_stack = module_stack ++ [module_name]
    {ast, {issues, new_stack}}
  end

  # Skip alias statements - we only care about actual function calls
  defp traverse({:alias, _, [{:__aliases__, _, [:Portal, :Safe]}]} = ast, acc, _issue_meta, _parent) do
    {ast, acc}
  end

  # Skip alias statements with as: - we only care about actual function calls
  defp traverse({:alias, _, [{:__aliases__, _, [:Portal, :Safe]}, _]} = ast, acc, _issue_meta, _parent) do
    {ast, acc}
  end

  # Check for direct Portal.Safe calls
  defp traverse({{:., meta, [{:__aliases__, _, [:Portal, :Safe]}, _]}, _, _} = ast, {issues, module_stack}, issue_meta, _parent) do
    if should_report?(module_stack) do
      issue = issue_for(meta[:line], issue_meta, module_stack)
      {ast, {[issue | issues], module_stack}}
    else
      {ast, {issues, module_stack}}
    end
  end

  # Check for Safe calls (when aliased)
  defp traverse({{:., meta, [{:__aliases__, _, [:Safe]}, _]}, _, _} = ast, {issues, module_stack}, issue_meta, _parent) do
    if should_report?(module_stack) do
      issue = issue_for(meta[:line], issue_meta, module_stack)
      {ast, {[issue | issues], module_stack}}
    else
      {ast, {issues, module_stack}}
    end
  end

  defp traverse(ast, acc, _issue_meta, _parent) do
    {ast, acc}
  end

  # Check if we're in a DB module anywhere in the module hierarchy
  defp should_report?(module_stack) do
    not Enum.any?(module_stack, fn module_name ->
      module_name == "DB" or String.ends_with?(module_name, ".DB")
    end)
  end

  defp issue_for(line_no, issue_meta, module_stack) do
    current_module = List.last(module_stack)
    location = if current_module, do: " (in module #{inspect(current_module)})", else: ""

    format_issue(
      issue_meta,
      message:
        "Portal.Safe should only be called from within a DB module#{location}. Create an inline DB module and move this call there.",
      trigger: "Portal.Safe",
      line_no: line_no
    )
  end
end
