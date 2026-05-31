defmodule BranchedLLM.ChatOrchestrator.StreamDispatcher do
  @moduledoc false

  alias ReqLLM.StreamResponse
  alias ReqLLM.StreamResponse.MetadataHandle

  @type dispatch_state :: %{
          on_event: function(),
          branch_id: String.t(),
          tool_usage_counts: map(),
          dispatch_tags: map() | nil
        }

  @type dispatch_result :: {:ok, dispatch_state()} | {:error, String.t()}

  @spec dispatch(map(), dispatch_state()) :: dispatch_result()
  def dispatch(
        %{} = stream_result,
        %{
          on_event: on_event_fn,
          branch_id: branch_id,
          tool_usage_counts: tool_usage_counts
        } = state
      )
      when is_map_key(stream_result, :stream) do
    on_event_fn.({:update_tool_usage_counts, tool_usage_counts})

    stream_response = stream_result.stream

    {_sent_any_chunks, full_text} =
      stream_response
      |> StreamResponse.tokens()
      |> Enum.reduce_while({false, ""}, fn chunk, {_, acc} ->
        on_event_fn.({:llm_chunk, branch_id, chunk})
        {:cont, {true, acc <> chunk}}
      end)

    metadata_handle = Map.get(stream_response, :metadata_handle)
    emit_metadata(state, branch_id, metadata_handle)

    {:ok, %{state | dispatch_tags: %{full_text: full_text}}}
  end

  def dispatch(%{} = stream_result, state) when is_map_key(stream_result, :tool_calls) do
    %{on_event: on_event_fn, branch_id: branch_id} = state

    emit_metadata(state, branch_id, Map.get(stream_result, :metadata_handle))

    tool_names =
      Enum.map_join(Map.get(stream_result, :tool_calls, []), ", ", &ReqLLM.ToolCall.name/1)

    on_event_fn.({:llm_status, branch_id, "Using #{tool_names}..."})

    {:ok,
     %{
       state
       | dispatch_tags: %{
           context: stream_result.context,
           tool_calls: stream_result.tool_calls,
           metadata_handle: Map.get(stream_result, :metadata_handle)
         }
     }}
  end

  def dispatch(_empty, _state) do
    {:error, "The AI did not return a response. Please try again."}
  end

  defp emit_metadata(
         %{on_event: on_event_fn, branch_id: branch_id},
         _branch_id,
         metadata_handle
       )
       when is_pid(metadata_handle) do
    emit_metadata_from_handle(on_event_fn, branch_id, metadata_handle)
  end

  defp emit_metadata(_llm_call_params, _branch_id, nil), do: :ok

  defp emit_metadata_from_handle(on_event_fn, branch_id, metadata_handle) do
    metadata = MetadataHandle.await(metadata_handle)

    on_event_fn.({:llm_metadata, branch_id, metadata})
    :ok
  end
end
