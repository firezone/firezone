defmodule Domain.Repo.Filter.Range do
  @typep value ::
           Domain.Repo.Filter.numeric_type()
           | Domain.Repo.Filter.datetime_type()
           | nil

  @type t :: %__MODULE__{
          from: value(),
          to: value()
        }

  defstruct from: nil,
            to: nil
end
