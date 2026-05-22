defmodule BranchedLLM.LLM.StreamResult do
  @moduledoc """
  Tagged-union result types for `send_message_stream/2`.

  Each variant clearly distinguishes the LLM's intent — content, tool call,
  empty, or error — eliminating the need for callers to inspect `tool_calls`
  lists or handle dummy streams.

  ## Variants

    * `%ContentResult{}` — The LLM is streaming text content.
    * `%ToolCallResult{}` — The LLM is invoking one or more tools.
    * `%EmptyResult{}` — The LLM returned neither content nor tool calls.
    * `%ErrorResult{}` — The LLM call failed.

  ## Usage

  The `ChatOrchestrator` pattern-matches on the struct type to decide how
  to proceed, rather than checking whether a `tool_calls` list is empty:

      case result do
        %ContentResult{} -> process_stream(result.stream, ...)
        %ToolCallResult{} -> handle_tool_call_execution(result.tool_calls, ...)
        %EmptyResult{} -> {:error, "no response"}
        %ErrorResult{} -> {:error, result.reason}
      end
  """

  alias ReqLLM.Context
  alias ReqLLM.StreamResponse
  alias ReqLLM.ToolCall

  defmodule ContentResult do
    @moduledoc """
    The LLM is streaming text content. The `stream` field is a live
    `StreamResponse` that can be iterated for token-by-token output.
    """

    defstruct [:stream]

    @type t :: %__MODULE__{
            stream: StreamResponse.t()
          }
  end

  defmodule ToolCallResult do
    @moduledoc """
    The LLM is invoking one or more tools. The `context` field carries
    the `ReqLLM.Context` from the original stream response (needed to
    append tool-call messages before the recursive LLM call).
    """

    defstruct [:tool_calls, :context]

    @type t :: %__MODULE__{
            tool_calls: list(ToolCall.t()),
            context: Context.t()
          }
  end

  defmodule EmptyResult do
    @moduledoc """
    The LLM returned neither content nor tool calls (empty stream).
    """

    defstruct []

    @type t :: %__MODULE__{}
  end

  defmodule ErrorResult do
    @moduledoc """
    The LLM call failed. The `reason` field carries the error term.
    """

    defstruct [:reason]

    @type t :: %__MODULE__{reason: term()}
  end

  @type t ::
          BranchedLLM.LLM.StreamResult.ContentResult.t()
          | BranchedLLM.LLM.StreamResult.ToolCallResult.t()
          | BranchedLLM.LLM.StreamResult.EmptyResult.t()
          | BranchedLLM.LLM.StreamResult.ErrorResult.t()
end
