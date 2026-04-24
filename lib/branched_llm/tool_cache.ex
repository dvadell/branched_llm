defmodule BranchedLLM.ToolCache do
  @moduledoc """
  Proxy module for tool result caching.

  Defaults to `BranchedLLM.ToolCache.InMemory` but can be configured to use
  `BranchedLLM.ToolCache.Ecto` or any other module implementing
  `BranchedLLM.ToolCacheBehaviour`.

  To configure:

      config :branched_llm, :tool_cache, BranchedLLM.ToolCache.Ecto

  If using Ecto, you also need to configure the repo:

      config :branched_llm, BranchedLLM.ToolCache,
        repo: MyApp.Repo

  """
  @behaviour BranchedLLM.ToolCacheBehaviour

  @impl true
  def get_result(tool_name, args) do
    get_impl().get_result(tool_name, args)
  end

  @impl true
  def save_result(tool_name, args, result) do
    get_impl().save_result(tool_name, args, result)
  end

  defp get_impl do
    Application.get_env(:branched_llm, :tool_cache, BranchedLLM.ToolCache.InMemory)
  end
end
