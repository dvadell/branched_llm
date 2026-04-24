defmodule BranchedLLM.ToolCache.InMemory do
  @moduledoc """
  A default in-memory cache implementation.
  Currently, it acts as a no-op cache (does not actually store results).
  This can be extended to use an Agent or ETS in the future.
  """
  @behaviour BranchedLLM.ToolCacheBehaviour

  @impl true
  def get_result(_tool_name, _args), do: :error

  @impl true
  def save_result(_tool_name, _args, _result), do: :ok
end
