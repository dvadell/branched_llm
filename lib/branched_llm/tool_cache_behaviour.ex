defmodule BranchedLLM.ToolCacheBehaviour do
  @moduledoc """
  Defines the interface for tool result caching.
  """

  @callback get_result(tool_name :: String.t(), args :: map()) :: {:ok, String.t()} | :error
  @callback save_result(tool_name :: String.t(), args :: map(), result :: String.t()) :: :ok
end
