defmodule FzHttp.Auth.Permission do
  @type resource :: module()

  @typedoc """
  The action to be performed on the resource, can be any atom but
  most contexts should mostly rely on:

    - `:view` - view list or get by id;
    - `:create` - create a new resource;
    - `:update_owned` - update a resource created by the same user;
    - `:delete_owned` - delete a resource created by the same user;
    - `:manage` - create, update or delete a resource create by any user.
  """
  @type action :: :view | :modify_owned | :manage | atom()

  @type t :: %__MODULE__{
          resource: resource(),
          action: action()
        }

  defstruct resource: nil,
            action: nil
end
