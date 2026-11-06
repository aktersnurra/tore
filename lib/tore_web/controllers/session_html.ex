defmodule ToreWeb.SessionHTML do
  use ToreWeb, :html

  embed_templates "session_html/*"

  def dev_routes?, do: Application.get_env(:tore, :dev_routes, false)
end
