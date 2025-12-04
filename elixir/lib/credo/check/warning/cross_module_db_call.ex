defmodule Credo.Check.Warning.CrossModuleDBCall do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Modules should not directly call into other modules' DB submodules.
      
      Each module should only call its own DB module functions. If you need
      to access data from another module, create a public function in that
      module that delegates to its DB module internally.
      """,
      params: []
    ]

  @doc false
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    
    # Extract the current module name from the file
    current_modules = extract_module_names(source_file)
    
    # Find all cross-module DB calls
    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta, current_modules), [])
  end

  defp extract_module_names(source_file) do
    Credo.Code.prewalk(source_file, &extract_module_name/2, [])
  end

  defp extract_module_name({:defmodule, _, [{:__aliases__, _, module_parts}, _]} = ast, acc) do
    module_name = Enum.join(module_parts, ".")
    {ast, [module_name | acc]}
  end

  defp extract_module_name(ast, acc) do
    {ast, acc}
  end

  # Check for calls like OtherModule.DB.function()
  defp traverse(
         {{:., meta, [{:__aliases__, _, module_path}, _func]}, _, _} = ast,
         issues,
         issue_meta,
         current_modules
       ) when length(module_path) >= 2 do
    if is_cross_module_db_call?(module_path, current_modules) do
      module_name = Enum.join(module_path, ".")
      issue = issue_for(meta[:line], issue_meta, module_name)
      {ast, [issue | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta, _current_modules) do
    {ast, issues}
  end

  defp is_cross_module_db_call?(module_path, current_modules) do
    # Check if this is a DB module call
    case List.last(module_path) do
      "DB" when length(module_path) >= 2 ->
        # Get the parent module (everything except "DB")
        parent_parts = Enum.take(module_path, length(module_path) - 1)
        parent_module = Enum.join(parent_parts, ".")
        
        # It's a cross-module call if the parent module is not in our current modules
        # and it's not a special allowed module
        not Enum.member?(current_modules, parent_module) and
        not Enum.member?(current_modules, parent_module <> ".DB") and
        not is_allowed_module?(parent_module)
      _ ->
        false
    end
  end

  # Allow certain system modules
  defp is_allowed_module?("Domain"), do: true
  defp is_allowed_module?("Domain.Safe"), do: true
  defp is_allowed_module?(_), do: false

  defp issue_for(line_no, issue_meta, module_name) do
    format_issue(
      issue_meta,
      message:
        "Cross-module DB call detected: #{module_name}. Modules should not call other modules' DB functions directly. Create a public API function instead.",
      trigger: module_name,
      line_no: line_no
    )
  end
end