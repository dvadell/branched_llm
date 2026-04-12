defmodule BranchedLLM.ChatBehaviour do
  @moduledoc """
  Behaviour for Chat AI interactions.

  Any module implementing this behaviour must provide the callbacks
  for creating contexts, sending messages, executing tools, and health checks.

  ## Example

      defmodule MyChat do
        @behaviour BranchedLLM.ChatBehaviour

        @impl true
        def new_context(system_prompt) do
          ReqLLM.Context.new([ReqLLM.Context.system(system_prompt)])
        end

        # ... implement other callbacks
      end

  """
  alias ReqLLM.Context
  alias ReqLLM.Tool

  @callback new_context(String.t()) :: Context.t()
  @callback reset_context(Context.t()) :: Context.t()
  @callback send_message_stream(String.t(), Context.t(), keyword()) ::
              {:ok, ReqLLM.StreamResponse.t(), (String.t() -> Context.t()), list()}
              | {:error, term()}
  @callback send_message(String.t(), Context.t(), keyword()) ::
              {:ok, String.t(), Context.t()} | {:error, term()}
  @callback execute_tool(Tool.t(), map()) :: {:ok, term()} | {:error, term()}
  @callback health_check() :: :ok | {:error, term()}
end
