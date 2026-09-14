defmodule PortalAPI.Plugs.RequestValidationError do
  @moduledoc """
  Renders OpenAPI request validation failures as RFC 9457 problem details.

  A problem with the request itself, such as a bad query parameter or a
  missing body wrapper, is a 400. A problem with a field inside the body is a
  422 with the same `validation_errors` shape changeset failures use, keyed
  from inside the wrapper so the two are interchangeable to clients.
  """

  @behaviour Plug

  alias OpenApiSpex.Cast.Error

  @impl Plug
  def init(errors), do: errors

  @impl Plug
  def call(conn, errors) do
    {request_errors, field_errors} = Enum.split_with(errors, &(length(path(&1)) <= 1))

    if request_errors == [] do
      PortalAPI.ProblemDetails.send(conn, 422, "The request body failed validation.", %{
        validation_errors: Enum.reduce(field_errors, %{}, &put_field_error/2)
      })
    else
      PortalAPI.ProblemDetails.send(
        conn,
        400,
        "The request could not be processed: " <> Enum.map_join(request_errors, ", ", &request_message/1)
      )
    end
  end

  defp put_field_error(%Error{} = error, acc) do
    [_wrapper | path] = path(error)
    {parents, [leaf]} = Enum.split(path, -1)
    keys = Enum.map(parents, &Access.key(&1, %{})) ++ [Access.key(leaf, [])]
    update_in(acc, keys, &[message(error) | &1])
  end

  defp path(%Error{path: path}), do: Enum.map(path, &to_string/1)

  defp request_message(%Error{reason: :missing_field, name: name}), do: "`#{name}` is required"

  defp request_message(%Error{reason: :invalid_type, type: type} = error) do
    "`#{List.last(path(error))}` must be #{article(type)} #{type}"
  end

  defp request_message(%Error{} = error) do
    case path(error) do
      [] -> message(error)
      [name] -> "`#{name}` #{message(error)}"
    end
  end

  defp article(type) when type in [:integer, :object, :array], do: "an"
  defp article(_type), do: "a"

  defp message(%Error{reason: :missing_field}), do: "can't be blank"
  defp message(%Error{reason: :null_value}), do: "can't be blank"
  defp message(%Error{reason: :invalid_type}), do: "is invalid"
  defp message(%Error{reason: :invalid_enum}), do: "is invalid"
  defp message(%Error{reason: :invalid_format}), do: "is invalid"
  defp message(%Error{reason: :unexpected_field}), do: "is not a known parameter"
  defp message(%Error{reason: :min_length, length: n}), do: "should be at least #{n} character(s)"
  defp message(%Error{reason: :max_length, length: n}), do: "should be at most #{n} character(s)"
  defp message(%Error{} = error), do: Error.message(error)
end
