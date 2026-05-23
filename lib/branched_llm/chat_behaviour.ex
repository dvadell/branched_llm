defmodule BranchedLLM.ChatBehaviour do
  @moduledoc """
  Behaviour for Chat AI interactions.

  Any module implementing this behaviour must provide the callbacks for creating
  contexts, sending messages, executing tools, and health checks.

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

  alias BranchedLLM.LLM.StreamResult
  alias ReqLLM.Context
  alias ReqLLM.StreamResponse
  alias ReqLLM.Tool

  @callback new_context(String.t()) :: Context.t()
  @callback reset_context(Context.t()) :: Context.t()
  @callback send_message_stream(Context.t(), keyword()) ::
              {:ok, StreamResult.t()} | {:error, term()}
  @callback send_message(String.t(), Context.t(), keyword()) ::
              {:ok, String.t(), Context.t()} | {:error, term()}
  @callback execute_tool(Tool.t(), map()) :: {:ok, term()} | {:error, term()}
  @callback health_check() :: :ok | {:error, term()}
  @callback default_model() :: String.t()

  @doc """
  Calls the LLM provider to stream text for the given messages.

  This callback exists primarily as a type-level boundary for Dialyzer:
  because `ReqLLM.StreamResponse.t/0` references `LLMDB.Model.t/0` (a
  transitive dependency not in this project's PLT), Dialyzer cannot fully
  infer the return type of `ReqLLM.stream_text/3`. Declaring it as a
  `@callback` forces Dialyzer to trust the spec as the function contract
  rather than tracing into the implementation body.
  """
  @callback stream_text(String.t(), Context.t(), keyword()) ::
              {:ok, StreamResponse.t()} | {:error, term()}
end
