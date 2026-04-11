defmodule BranchedLLM.ChatBehaviour do
  @moduledoc """
  Behaviour defining the chat interface for LLM interactions.
  """

  @callback send_message_stream(message :: String.t(), context :: ReqLLM.Context.t(), opts :: Keyword.t()) ::
              {:ok, ReqLLM.StreamResponse.t(), (ReqLLM.Context.t() -> ReqLLM.Context.t()), [ReqLLM.ToolCall.t()]}
              | {:error, term()}

  @callback new_context(content :: String.t()) :: ReqLLM.Context.t()

  @callback execute_tool(tool :: map(), args :: map()) :: {:ok, String.t()} | {:error, term()}
end
