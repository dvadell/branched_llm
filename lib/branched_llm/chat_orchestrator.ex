defmodule BranchedLLM.ChatOrchestrator do
  @moduledoc """
  Orchestrates the LLM request/response lifecycle, including tool calls and streaming.

  This module is **domain-agnostic** — it knows nothing about education, students, or teachers.
  It communicates with a caller process (e.g., a LiveView) via a well-defined message protocol.

  ## Message Protocol

  The orchestrator sends the following messages through the `on_event` function,
  typically to the caller pid:

  * `{:llm_chunk, branch_id, chunk}` — A streaming text chunk from the LLM
  * `{:llm_end, branch_id, context_builder}` — The stream is complete; `context_builder`
    is a function `(String.t() -> ReqLLM.Context.t())` that builds the final context
  * `{:llm_status, branch_id, status}` — A status update (e.g., "Thinking...", "Using calculator...")
  * `{:llm_error, branch_id, error_message}` — An error occurred during the LLM request
  * `{:llm_tool_called, branch_id, tool_call}` — The LLM requested a tool call; `tool_call`
    is a map with `:id`, `:name`, and `:arguments` keys
  * `{:update_tool_usage_counts, counts}` — Updated tool usage counts for the caller to track

  The caller may also send messages back (e.g., to cancel a task), but those are handled
  externally via the `active_task` PID in `BranchedChat`.

  ## Example

      caller_pid = self()

      params = %{
        message: "What is 2+2?",
        llm_context: context,
        on_event: fn event -> send(caller_pid, event) end,
        llm_tools: [calculator_tool],
        chat_mod: BranchedLLM.Chat,
        tool_usage_counts: %{},
        branch_id: "main"
      }

      BranchedLLM.ChatOrchestrator.run(params)
  """

  use Retry

  require Logger

  alias BranchedLLM.LLM.StreamResult.{ContentResult, EmptyResult, ToolCallResult}
  alias BranchedLLM.LLMErrorFormatter
  alias BranchedLLM.ToolHandler

  alias ReqLLM.Context
  alias ReqLLM.StreamResponse.MetadataHandle
  alias ReqLLM.ToolCall

  @type llm_call_params :: %{
          message: String.t(),
          llm_context: ReqLLM.Context.t(),
          on_event: fun(),
          llm_tools: list(),
          chat_mod: module(),
          tool_usage_counts: map(),
          branch_id: String.t()
        }

  @doc """
  Starts the LLM request process in a separate task.

  The task communicates with the caller via messages defined in the module doc.
  """
  @spec run(llm_call_params()) :: {:ok, pid()}
  def run(params) do
    Task.start(fn ->
      result =
        retry with: constant_backoff(100) |> Stream.take(10) do
          case process_llm_request(params) do
            :ok ->
              :ok

            {:error, reason} ->
              params.on_event.({:llm_status, params.branch_id, "Retrying..."})
              {:error, reason}
          end
        after
          result -> result
        else
          error -> error
        end

      case result do
        :ok -> :ok
        {:error, reason} -> params.on_event.({:llm_error, params.branch_id, reason})
      end
    end)
  end

  @spec process_llm_request(llm_call_params()) :: :ok | {:error, String.t()}
  defp process_llm_request(
         %{message: message, llm_context: llm_context, llm_tools: llm_tools, chat_mod: chat_mod} =
           llm_call_params
       ) do
    chat_mod.send_message_stream(message, llm_context, tools: llm_tools)
    |> dispatch(llm_call_params)
  rescue
    exception -> {:error, LLMErrorFormatter.format(exception)}
  end

  # Each dispatch clause handles one LLM intent, with all event emissions
  # local and explicit. Pattern matching decides which branch runs.

  @spec dispatch({:ok, ContentResult.t()}, llm_call_params()) :: :ok | {:error, String.t()}
  defp dispatch(
         {:ok, %ContentResult{stream: stream_response, context_builder: context_builder}},
         %{on_event: on_event, tool_usage_counts: tool_usage_counts, branch_id: branch_id}
       ) do
    on_event.({:update_tool_usage_counts, tool_usage_counts})

    start_time = :erlang.monotonic_time(:millisecond)

    sent_any_chunks =
      stream_response
      |> ReqLLM.StreamResponse.tokens()
      |> Enum.reduce_while(false, fn chunk, _acc ->
        on_event.({:llm_chunk, branch_id, chunk})
        {:cont, true}
      end)

    end_time = :erlang.monotonic_time(:millisecond)
    Logger.info("LLM streaming of answer took #{end_time - start_time}ms")

    metadata = MetadataHandle.await(stream_response.metadata_handle)
    Logger.info("LLM stream complete metadata: #{inspect(metadata)}")

    if sent_any_chunks do
      on_event.({:llm_end, branch_id, context_builder})
      :ok
    else
      {:error, "The AI did not return a response. Please try again."}
    end
  end

  @spec dispatch({:ok, ToolCallResult.t()}, llm_call_params()) :: :ok | {:error, String.t()}
  defp dispatch(
         {:ok, %ToolCallResult{tool_calls: tool_calls, context: context}},
         llm_call_params
       ) do
    %{on_event: on_event, branch_id: branch_id} = llm_call_params

    Enum.each(tool_calls, fn tool_call ->
      on_event.({:llm_tool_called, branch_id, ToolCall.to_map(tool_call)})
    end)

    tool_names = Enum.map_join(tool_calls, ", ", &ToolCall.name/1)
    on_event.({:llm_status, branch_id, "Using #{tool_names}..."})

    updated_params = execute_tool_calls(tool_calls, %{llm_call_params | llm_context: context})
    process_llm_request(%{updated_params | message: ""})
  end

  @spec dispatch({:ok, EmptyResult.t()}, llm_call_params()) :: {:error, String.t()}
  defp dispatch({:ok, %EmptyResult{}}, _llm_call_params) do
    {:error, "The AI did not return a response. Please try again."}
  end

  @spec dispatch({:error, term()}, llm_call_params()) :: {:error, String.t()}
  defp dispatch({:error, reason}, _llm_call_params) do
    {:error, "Error: #{inspect(reason)}"}
  end

  # Executes tool calls, partitioning them into those under the usage limit
  # (to be executed) and those at the limit (to receive a fake "limit reached"
  # result). Returns updated llm_call_params with the new context and counts.

  @spec execute_tool_calls(list(ToolCall.t()), llm_call_params()) :: llm_call_params()
  defp execute_tool_calls(
         tool_calls,
         %{
           llm_context: llm_context,
           llm_tools: llm_tools,
           chat_mod: chat_mod,
           tool_usage_counts: tool_usage_counts
         } = llm_call_params
       ) do
    {to_execute, limited_results, new_counts} =
      partition_tool_calls(tool_calls, tool_usage_counts)

    llm_context_after_handling =
      if Enum.empty?(to_execute) do
        Context.append(llm_context, Context.assistant("", tool_calls: tool_calls))
      else
        llm_context_with_assistant =
          Context.append(llm_context, Context.assistant("", tool_calls: to_execute))

        ToolHandler.handle_tool_calls(to_execute, llm_context_with_assistant, llm_tools, chat_mod)
      end

    updated_context =
      Enum.reduce(limited_results, llm_context_after_handling, fn tr, acc ->
        Context.append(acc, tr)
      end)

    %{llm_call_params | llm_context: updated_context, tool_usage_counts: new_counts}
  end

  @spec partition_tool_calls(list(ToolCall.t()), map()) ::
          {list(ToolCall.t()), list(Context.t()), map()}
  defp partition_tool_calls(tool_calls, tool_usage_counts) do
    Enum.reduce(tool_calls, {[], [], tool_usage_counts}, fn tool_call,
                                                            {exec_acc, limited_acc, counts_acc} ->
      tool_name = ToolCall.name(tool_call)
      tool_name_atom = String.to_atom(tool_name)
      current_count = Map.get(counts_acc, tool_name_atom, 0)

      if current_count < 10 do
        {[tool_call | exec_acc], limited_acc,
         Map.put(counts_acc, tool_name_atom, current_count + 1)}
      else
        tool_result =
          Context.tool_result(tool_call.id, "Tool limit reached. Summarize with what you have")

        {exec_acc, [tool_result | limited_acc], counts_acc}
      end
    end)
    |> then(fn {exec, limited, counts} ->
      {Enum.reverse(exec), Enum.reverse(limited), counts}
    end)
  end
end
