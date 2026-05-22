defmodule BranchedLLM.ChatOrchestrator do
  @moduledoc """
  Orchestrates the LLM request/response lifecycle, including tool calls and streaming.

  This module is **domain-agnostic** — it knows nothing about education, students, or teachers.
  It communicates with a caller process (e.g., a LiveView) via a well-defined message protocol.

  ## Message Protocol

  The orchestrator sends the following messages through the `on_event` function,
  typically to the caller pid:

    * `{:llm_chunk, branch_id, chunk}` — A streaming text chunk from the LLM
    * `{:llm_end, branch_id, full_text}` — The stream is complete; `full_text` is the full
      accumulated text of the assistant's response
    * `{:llm_status, branch_id, status}` — A status update (e.g., "Thinking...", "Using calculator...")
    * `{:llm_error, branch_id, error_message}` — An error occurred during the LLM request
    * `{:update_tool_usage_counts, counts}` — Updated tool usage counts for the caller to track

  The caller may also send messages back (e.g., to cancel a task), but those are handled
  externally via the `active_task` PID in `BranchedChat`.

  ## Example

      caller_pid = self()

      params = %{
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

  @type llm_call_params :: %{
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
         %{
           llm_context: llm_context,
           on_event: _event_fn,
           llm_tools: llm_tools,
           chat_mod: chat_mod
         } = llm_call_params
       ) do
    case chat_mod.send_message_stream(llm_context, tools: llm_tools) do
      {:ok, %ContentResult{} = result} ->
        handle_content_result(result, llm_call_params)

      {:ok, %ToolCallResult{} = result} ->
        handle_tool_call_result(result, llm_call_params)

      {:ok, %EmptyResult{}} ->
        {:error, "The AI did not return a response. Please try again."}

      {:error, reason} ->
        {:error, "Error: #{inspect(reason)}"}
    end
  rescue
    exception -> {:error, LLMErrorFormatter.format(exception)}
  end

  @spec handle_content_result(ContentResult.t(), llm_call_params()) :: :ok | {:error, String.t()}
  defp handle_content_result(
         %ContentResult{stream: stream_response},
         %{
           on_event: on_event_fn,
           tool_usage_counts: tool_usage_counts,
           branch_id: branch_id
         }
       ) do
    if process_stream(
         stream_response,
         on_event_fn,
         tool_usage_counts,
         branch_id
       ) do
      :ok
    else
      {:error, "The AI did not return a response. Please try again."}
    end
  end

  @spec handle_tool_call_result(ToolCallResult.t(), llm_call_params()) ::
          :ok | {:error, String.t()}
  defp handle_tool_call_result(
         %ToolCallResult{tool_calls: tool_calls, context: context},
         llm_call_params
       ) do
    updated_llm_call_params = %{llm_call_params | llm_context: context}
    next_llm_call_params = handle_tool_call_execution(tool_calls, updated_llm_call_params)
    process_llm_request(next_llm_call_params)
  end

  @spec handle_tool_call_execution(list(), llm_call_params()) :: llm_call_params()
  defp handle_tool_call_execution(
         tool_calls,
         %{
           llm_context: llm_context,
           llm_tools: llm_tools,
           chat_mod: chat_mod,
           tool_usage_counts: tool_usage_counts,
           on_event: on_event_fn,
           branch_id: branch_id
         } = llm_call_params
       ) do
    tool_names = Enum.map_join(tool_calls, ", ", &ReqLLM.ToolCall.name/1)
    on_event_fn.({:llm_status, branch_id, "Using #{tool_names}..."})

    {tool_calls_to_execute, tool_results_for_limited_tools, new_tool_usage_counts} =
      Enum.reduce(tool_calls, {[], [], tool_usage_counts}, fn tool_call,
                                                              {exec_acc, limited_acc, counts_acc} ->
        tool_name = ReqLLM.ToolCall.name(tool_call)
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

    tool_calls_to_execute = Enum.reverse(tool_calls_to_execute)
    tool_results_for_limited_tools = Enum.reverse(tool_results_for_limited_tools)

    llm_context_after_tool_handling =
      if Enum.empty?(tool_calls_to_execute) do
        # If no tools are executed, just append the original tool calls to the context
        Context.append(llm_context, Context.assistant("", tool_calls: tool_calls))
      else
        # Execute allowed tools and get updated context
        llm_context_with_assistant_tool_calls =
          Context.append(llm_context, Context.assistant("", tool_calls: tool_calls_to_execute))

        ToolHandler.handle_tool_calls(
          tool_calls_to_execute,
          llm_context_with_assistant_tool_calls,
          llm_tools,
          chat_mod
        )
      end

    updated_llm_context =
      Enum.reduce(tool_results_for_limited_tools, llm_context_after_tool_handling, fn tr, acc ->
        Context.append(acc, tr)
      end)

    %{
      llm_call_params
      | llm_context: updated_llm_context,
        tool_usage_counts: new_tool_usage_counts
    }
  end

  @spec process_stream(
          ReqLLM.StreamResponse.t(),
          any(),
          map(),
          String.t()
        ) :: boolean()
  defp process_stream(
         stream_response,
         on_event_fn,
         tool_usage_counts,
         branch_id
       ) do
    on_event_fn.({:update_tool_usage_counts, tool_usage_counts})
    start_time = :erlang.monotonic_time(:millisecond)

    {sent_any_chunks, full_text} =
      stream_response
      |> ReqLLM.StreamResponse.tokens()
      |> Enum.reduce_while({false, ""}, fn chunk, {_, acc} ->
        on_event_fn.({:llm_chunk, branch_id, chunk})
        {:cont, {true, acc <> chunk}}
      end)

    end_time = :erlang.monotonic_time(:millisecond)
    Logger.info("LLM streaming of answer took #{end_time - start_time}ms")

    metadata = MetadataHandle.await(stream_response.metadata_handle)
    Logger.info("LLM stream complete metadata: #{inspect(metadata)}")

    if sent_any_chunks do
      on_event_fn.({:llm_end, branch_id, full_text})
    end

    sent_any_chunks
  end
end
