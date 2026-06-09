defmodule BranchedLLM.ChatBehaviour do
  @moduledoc """
  Behaviour for the frontend Chat API.

  Modules implementing this behaviour provide the user-facing convenience
  functions: synchronous message sending, context creation/reset, and
  health checks. These are the functions that callers use directly — as
  opposed to `BranchedLLM.ChatClientBehaviour`, which defines the contract
  between the orchestrator and its LLM backend (`chat_mod`).

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

  @callback new_context(String.t()) :: Context.t()
  @callback reset_context(Context.t()) :: Context.t()
  @callback send_message(String.t(), Context.t(), keyword()) ::
              {:ok, String.t() | map(), Context.t()} | {:error, term()}
  @callback get_history(Context.t()) :: list()
  @callback health_check() :: :ok | {:error, term()}
end
