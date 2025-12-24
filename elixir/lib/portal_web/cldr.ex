defmodule Web.CLDR do
  use Cldr,
    locales: ["en"],
    providers: [Cldr.Number, Cldr.Calendar, Cldr.DateTime]
end
