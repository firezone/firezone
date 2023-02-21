defmodule FzHttpWeb.ErrorHelpers do
  @moduledoc """
  Conveniences for translating and building error messages.
  """
  use Phoenix.HTML
  import Ecto.Changeset, only: [traverse_errors: 2]

  def aggregated_errors(%Ecto.Changeset{} = changeset) do
    traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn
        {key, {:array, value}}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))

        {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.reduce("", fn {key, value}, acc ->
      joined_errors = Enum.join(value, "; ")
      "#{acc}#{key}: #{joined_errors}\n"
    end)
  end

  @doc """
  Generates tag for inlined form input errors.
  """
  def error_tag(form, field) do
    values = Keyword.get_values(form.errors, field)

    values
    |> Enum.map(fn error ->
      content_tag(:span, translate_error(error),
        class: "help-block"
        # XXX: data: [phx_error_for: input_id(form, field)]
      )
    end)
    |> Enum.intersperse(", ")
  end

  @doc """
  Adds "is-danger" to input elements that have errors
  """
  def input_error_class(form, field) do
    case Keyword.get_values(form.errors, field) do
      [] ->
        ""

      _ ->
        "is-danger"
    end
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate "is invalid" in the "errors" domain
    #     dgettext("errors", "is invalid")
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # Because the error messages we show in our forms and APIs
    # are defined inside Ecto, we need to translate them dynamically.
    # This requires us to call the Gettext module passing our gettext
    # backend as first argument.
    #
    # Note we use the "errors" domain, which means translations
    # should be written to the errors.po file. The :count option is
    # set by Ecto and indicates we should also apply plural rules.
    if count = opts[:count] do
      Gettext.dngettext(FzHttpWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(FzHttpWeb.Gettext, "errors", msg, opts)
    end
  end
end
