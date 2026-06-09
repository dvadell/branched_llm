defmodule BranchedLLM.ChatClientBehaviour do
  @moduledoc """
  Behaviour for the LLM client contract used by `ChatOrchestrator`.

  Modules implementing this behaviour provide the low-level LLM operations
  that the orchestrator calls into: streaming messages, executing tools,
  resolving the default model, and calling the provider's stream-text API.

  This is the `chat_mod` interface — the contract between the orchestrator
  and whatever LLM backend it drives.

  ## Example

      defmodule MyClient do
        @behaviour BranchedLLM.ChatClientBehaviour

        @impl true
        def send_message_stream(context, opts) do
          # ... call your LLM provider
        end

        # ... implement other callbacks
      end
  """

  alias BranchedLLM.LLM.StreamResult
  alias ReqLLM.Context
  alias ReqLLM.StreamResponse
  alias ReqLLM.Tool

  @callback send_message_stream(Context.t(), keyword()) ::
              {:ok, StreamResult.t()} | {:error, term()}

  @callback execute_tool(Tool.t(), map()) :: {:ok, term()} | {:error, term()}

  @callback default_model() :: ReqLLM.model_input()

  @doc """
  Calls the LLM provider to stream text for the given messages.

  This callback exists primarily as a type-level boundary for Dialyzer:
  because `ReqLLM.StreamResponse.t/0` references `LLMDB.Model.t/0`
  (a transitive dependency not in this project's PLT), Dialyzer cannot
  fully infer the return type of `ReqLLM.stream_text/3`. Declaring it as
  a `@callback` forces Dialyzer to trust the spec as the function contract
  rather than tracing into the implementation body.
  """
  @callback stream_text(ReqLLM.model_input(), Context.t(), keyword()) ::
              {:ok, StreamResponse.t()} | {:error, term()}
end
