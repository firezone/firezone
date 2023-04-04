defmodule Domain.Auth.Subject do
  alias Domain.Auth.{Permission, Context}

  @type actor ::
          {:user, %Domain.Users.User{}}
          | {:api_token, %Domain.ApiTokens.ApiToken{}}
          | :system

  @type permission :: Permission.t()

  @type t :: %__MODULE__{
          actor: actor(),
          permissions: MapSet.t(permission),
          context: Context.t()
        }

  defstruct actor: nil,
            permissions: MapSet.new(),
            context: %Context{}

  def actor_type(%__MODULE__{actor: {actor_type, _}}), do: actor_type
  def actor_type(%__MODULE__{actor: actor_type}), do: actor_type
end
