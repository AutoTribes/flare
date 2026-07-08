defmodule Flare.Audit.LogWorker do
  @moduledoc "Oban worker that persists an audit log row off the request path."
  use Oban.Worker, queue: :audit, max_attempts: 3
  alias Flare.{Audit.AuditLog, Repo}

  @impl true
  def perform(%Oban.Job{args: args}) do
    %AuditLog{} |> AuditLog.changeset(args) |> Repo.insert()
  end
end
