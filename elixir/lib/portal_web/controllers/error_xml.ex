defmodule Web.ErrorXML do
  use Web, :xml

  # If you want to customize your error pages,
  # uncomment the embed_templates/1 call below
  # and add pages to the error directory:
  #
  #   * lib/web_web/controllers/error_xml/404.xml.heex
  #   * lib/web_web/controllers/error_xml/500.xml.heex
  #
  # embed_templates "error_xml/*"

  # The default is to render a plain text page based on
  # the template name. For example, "404.xml" becomes
  # "Not Found".
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
