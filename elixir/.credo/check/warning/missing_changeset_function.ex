defmodule Credo.Check.Warning.MissingChangesetFunction do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Schema modules should define a `changeset/1` function that accepts an Ecto.Changeset.

      This ensures a consistent pattern across the codebase where changesets are created
      and validated in a predictable way.

      ## Examples

      Good:

          defmodule Portal.Account do
            use Ecto.Schema
            import Ecto.Changeset

            schema "accounts" do
              field :name, :string
              timestamps()
            end

            def changeset(changeset) do
              changeset
              |> validate_required([:name])
              |> validate_length(:name, min: 3, max: 64)
            end
          end

          # Or with explicit type annotation:
          def changeset(%Ecto.Changeset{} = changeset) do
            changeset
            |> validate_required([:name])
          end

      Embedded schemas typically use changeset/2:

          defmodule Portal.Account.Metadata do
            use Ecto.Schema
            import Ecto.Changeset

            @primary_key false
            embedded_schema do
              field :stripe_id, :string
            end

            def changeset(metadata \\\\ %__MODULE__{}, attrs) do
              metadata
              |> cast(attrs, [:stripe_id])
            end
          end

      ## Exceptions

      Simple schemas that don't accept user input or validation (like audit logs,
      processed events, or read-only schemas) may not need a changeset function.
      """,
      params: []
    ]

  @doc false
  def run(source_file, params \\\\ []) do
    issue_meta = IssueMeta.for(source_file, params)

    # First pass: collect information about the module
    state = analyze_module(source_file)

    # Second pass: generate issues if needed
    if should_issue_warning?(state) do
      [issue_for(state.defmodule_line || 1, state.module_name, issue_meta)]
    else
      []
    end
  end

  defp analyze_module(source_file) do
    initial_state = %{
      uses_ecto_schema: false,
      has_changeset: false,
      is_embedded: false,
      module_name: nil,
      defmodule_line: nil
    }

    Credo.Code.prewalk(source_file, &collect_info(&1, &2), initial_state)
  end

  # Detect if the module uses Ecto.Schema
  defp collect_info(
         {:use, _, [{:__aliases__, _, [:Ecto, :Schema]} | _]} = ast,
         state
       ) do
    {ast, %{state | uses_ecto_schema: true}}
  end

  # Detect defmodule to capture module name and line
  defp collect_info(
         {:defmodule, meta, [{:__aliases__, _, module_parts}, _body]} = ast,
         state
       ) do
    module_name = Enum.join(module_parts, ".")
    {ast, %{state | module_name: module_name, defmodule_line: meta[:line]}}
  end

  # Detect @primary_key false (indicator of embedded schema)
  defp collect_info(
         {:@, _, [{:primary_key, _, [false]}]} = ast,
         state
       ) do
    {ast, %{state | is_embedded: true}}
  end

  # Detect embedded_schema (definitive indicator)
  defp collect_info(
         {:embedded_schema, _, _} = ast,
         state
       ) do
    {ast, %{state | is_embedded: true}}
  end

  # Detect changeset/1 function
  defp collect_info(
         {:def, _, [{:changeset, _, [_arg]}, _body]} = ast,
         state
       ) do
    {ast, %{state | has_changeset: true}}
  end

  defp collect_info(ast, state) do
    {ast, state}
  end

  # Only issue warning for non-embedded schemas that use Ecto.Schema but don't have changeset/1
  defp should_issue_warning?(state) do
    state.uses_ecto_schema and not state.has_changeset and not state.is_embedded
  end

  defp issue_for(line_no, module_name, issue_meta) do
    module_info = if module_name, do: " (#{module_name})", else: ""

    format_issue(
      issue_meta,
      message:
        "Schema module#{module_info} should define a changeset/1 function that accepts an Ecto.Changeset. " <>
          "If this schema doesn't accept user input, you can ignore this warning.",
      trigger: "use Ecto.Schema",
      line_no: line_no
    )
  end
end
