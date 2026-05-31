defmodule BranchedLLM.ChatOrchestrator.CallbackStream do
  @moduledoc false

  alias BranchedLLM.ChatOrchestrator.StreamDispatcher
  alias BranchedLLM.LLM.StreamResult.{ContentResult, ToolCallResult}

  def run(%{llm_context: context, chat_mod: chat_mod} = params) do
    stream_opts = BranchedLLM.ChatOrchestrator.build_stream_opts(params)

    case chat_mod.send_message_stream(context, stream_opts) do
      {:ok, %ContentResult{} = result} ->
        case StreamDispatcher.dispatch(result, for_event(params)) do
          {:ok, delta} -> handle_content(delta, params)
          {:error, reason} -> {:error, reason}
        end

      {:ok, %ToolCallResult{} = result} ->
        case StreamDispatcher.dispatch(result, for_event(params)) do
          {:ok, delta} -> handle_tool_call(delta, params)
          {:error, reason} -> {:error, reason}
        end

      {:ok, %BranchedLLM.LLM.StreamResult.EmptyResult{}} ->
        {:error, "The AI did not return a response. Please try again."}

      {:error, reason} ->
        {:error, "Error: #{inspect(reason)}"}
    end
  rescue
    exception ->
      {:error, BranchedLLM.LLMErrorFormatter.format(exception)}
  end

  defp for_event(params) do
    %{
      on_event: Map.fetch!(params, :on_event),
      branch_id: Map.fetch!(params, :branch_id),
      tool_usage_counts: Map.get(params, :tool_usage_counts, %{}),
      dispatch_tags: nil
    }
  end

  defp handle_content(%{dispatch_tags: %{full_text: text}}, params) do
    params.on_event.({:llm_end, params.branch_id, text})
    :ok
  end

  defp handle_tool_call(
         %{dispatch_tags: %{context: context, tool_calls: tool_calls}},
         params
       ) do
    if structured_output_tool_call?(tool_calls) do
      handle_structured_output_tool_call(tool_calls, params)
    else
      next =
        BranchedLLM.ToolHandler.update_params_with_tool_results(tool_calls, %{
          params
          | llm_context: context
        })

      __MODULE__.run(next)
    end
  end

  defp structured_output_tool_call?(tool_calls) do
    Enum.any?(tool_calls, fn tool_call ->
      ReqLLM.ToolCall.name(tool_call) == "__structured_output__"
    end)
  end

  defp handle_structured_output_tool_call(tool_calls, params) do
    structured_call =
      Enum.find(tool_calls, fn tc ->
        ReqLLM.ToolCall.name(tc) == "__structured_output__"
      end)

    if structured_call do
      args_map = ReqLLM.ToolCall.args_map(structured_call) || %{}
      params.on_event.({:llm_end, params.branch_id, args_map})
      :ok
    else
      {:error, "Structured output tool call not found"}
    end
  end
end
