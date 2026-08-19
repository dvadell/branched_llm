defmodule BranchedLLM.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: BranchedLLM.ChatOrchestrator.TaskSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: BranchedLLM.Supervisor)
  end
end
