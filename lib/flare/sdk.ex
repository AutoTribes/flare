defmodule Flare.SDK do
  @moduledoc "Public facade for the reference Flare Elixir SDK. See Flare.SDK.Client."
  alias Flare.SDK.Client

  defdelegate start_link(opts), to: Client
  defdelegate is_enabled(pid, flag, ctx \\ %{}), to: Client
  defdelegate variation(pid, flag, ctx \\ %{}, default \\ nil), to: Client
  defdelegate json(pid, flag, ctx \\ %{}, default \\ nil), to: Client
  defdelegate identify(pid, ctx), to: Client
  defdelegate refresh(pid), to: Client
  defdelegate subscribe(pid, subscriber), to: Client
  defdelegate offline_mode(pid), to: Client
  defdelegate bootstrap(pid, payload), to: Client
end
