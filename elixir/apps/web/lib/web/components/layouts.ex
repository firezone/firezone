defmodule Web.Layouts do
  use Web, :html
  import Web.Endpoint, only: [static_path: 1]

  embed_templates "layouts/*"
end
