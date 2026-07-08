defmodule Flare.Redis do
  @moduledoc "Thin wrapper over the named Redix connection for non-blocking commands."
  @conn :flare_redix
  def command(cmd), do: Redix.command(@conn, cmd)
  def command!(cmd), do: Redix.command!(@conn, cmd)
end
