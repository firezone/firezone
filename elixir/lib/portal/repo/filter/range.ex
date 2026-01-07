defmodule Portal.Repo.Filter.Range do
  @typep value ::
           Portal.Repo.Filter.numeric_type()
           | Portal.Repo.Filter.datetime_type()
           | nil

  @type t :: %__MODULE__{
          from: value(),
          to: value()
        }

  defstruct from: nil,
            to: nil
end
