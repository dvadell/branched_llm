defmodule BranchedLLM.Orchestrator do
  @moduledoc """
  A process-based orchestrator for BranchedLLM.
  Handles asynchronous LLM calls, tool execution, and queuing.
  """
  use Retry
  require Logger

  alias BranchedLLM.Message
  alias BranchedLLM.ToolHandler
  alias ReqLLM.Context

  @type tree :: BranchedLLM.Tree.t()
  @type opts :: Keyword.t()

  @doc """
  Starts the LLM request for a given message on a branch.
  """
  @spec run(tree(), String.t(), Message.t(), opts()) :: {:ok, pid()}
  def run(tree, branch_id, message, opts \\ []) do
    caller_pid = opts[:caller_pid] || self()
    llm_tools = opts[:llm_tools] || []
    tool_usage_counts = opts[:tool_usage_counts] || %{}

    # Emit telemetry start
    :telemetry.execute([:branched_llm, :run, :start], %{system_time: System.system_time()}, %{
      branch_id: branch_id
    })

    Task.start(fn ->
      do_run(tree, branch_id, message, caller_pid, llm_tools, tool_usage_counts)
    end)
  end

  defp do_run(tree, branch_id, message, caller_pid, llm_tools, tool_usage_counts) do
    chat_mod = tree.chat_module
    branch = tree.branches[branch_id]

    # We use a recursive loop to handle tool calls (Reason-Act-Answer)
    result =
      execute_loop(
        message,
        branch.context,
        branch_id,
        caller_pid,
        llm_tools,
        chat_mod,
        tool_usage_counts
      )

    case result do
      {:ok, _final_context} ->
        :telemetry.execute([:branched_llm, :run, :stop], %{duration: 0}, %{
          branch_id: branch_id,
          status: :ok
        })

        :ok

      {:error, reason} ->
        :telemetry.execute([:branched_llm, :run, :stop], %{duration: 0}, %{
          branch_id: branch_id,
          status: :error,
          reason: reason
        })

        send(caller_pid, {:llm_error, branch_id, reason})
    end
  end

  defp execute_loop(
         message,
         context,
         branch_id,
         caller_pid,
         llm_tools,
         chat_mod,
         tool_usage_counts
       ) do
    retry with: constant_backoff(100) |> Stream.take(3) do
      case chat_mod.send_message_stream(message, context, tools: llm_tools) do
        {:ok, stream_response, context_builder, tool_calls} ->
          handle_response(
            stream_response,
            context_builder,
            tool_calls,
            branch_id,
            caller_pid,
            llm_tools,
            chat_mod,
            tool_usage_counts
          )

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    after
      result -> result
    else
      error -> error
    end
  end

  defp handle_response(
         stream_response,
         context_builder,
         tool_calls,
         branch_id,
         caller_pid,
         llm_tools,
         chat_mod,
         tool_usage_counts
       ) do
    if Enum.empty?(tool_calls) do
      # Normal stream
      consume_stream(stream_response, context_builder, branch_id, caller_pid)
    else
      # Tool calls
      send(caller_pid, {:llm_tool_calls, branch_id, tool_calls, context_builder})

      # Execute tools
      {updated_context, new_usage_counts} =
        execute_tools(
          tool_calls,
          stream_response.context,
          llm_tools,
          chat_mod,
          tool_usage_counts,
          branch_id,
          caller_pid
        )

      send(caller_pid, {:update_tool_usage_counts, new_usage_counts})

      # Recurse
      execute_loop(
        "",
        updated_context,
        branch_id,
        caller_pid,
        llm_tools,
        chat_mod,
        new_usage_counts
      )
    end
  end

  defp consume_stream(stream_response, context_builder, branch_id, caller_pid) do
    stream_response
    |> ReqLLM.StreamResponse.tokens()
    |> Enum.each(fn chunk ->
      send(caller_pid, {:llm_chunk, branch_id, chunk})
    end)

    send(caller_pid, {:llm_done, branch_id, context_builder})
    {:ok, stream_response.context}
  end

  defp execute_tools(
         tool_calls,
         context,
         llm_tools,
         chat_mod,
         tool_usage_counts,
         branch_id,
         caller_pid
       ) do
    tool_names = Enum.map_join(tool_calls, ", ", &ReqLLM.ToolCall.name/1)
    send(caller_pid, {:llm_status, branch_id, "Using #{tool_names}..."})

    # Logic for tool limiting (reusing current logic)
    {tools_to_execute, tools_to_limit, updated_usage_counts} =
      Enum.reduce(tool_calls, {[], [], tool_usage_counts}, fn tool_call,
                                                              {exec_list, limit_list, counts} ->
        tool_name = ReqLLM.ToolCall.name(tool_call)
        usage_count = Map.get(counts, tool_name, 0)

        if usage_count < 10 do
          {[tool_call | exec_list], limit_list, Map.put(counts, tool_name, usage_count + 1)}
        else
          {[tool_call | exec_list],
           [Context.tool_result(tool_call.id, "Limit reached") | limit_list], counts}
        end
      end)

    # Note: handle_tool_calls in Cara currently appends the assistant message itself.
    # We might want to move that logic into a generic ToolHandler in the library too.

    ctx_with_assistant =
      Context.append(context, Context.assistant("", tool_calls: Enum.reverse(tools_to_execute)))

    final_ctx =
      ToolHandler.handle_tool_calls(
        Enum.reverse(tools_to_execute),
        ctx_with_assistant,
        llm_tools,
        chat_mod
      )

    updated_ctx = Enum.reduce(tools_to_limit, final_ctx, &Context.append(&2, &1))

    {updated_ctx, updated_usage_counts}
  end
end
