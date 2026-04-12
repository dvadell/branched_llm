defmodule BranchedLLM.LLM.StreamParser do
  @moduledoc """
  A pure functional module for parsing and processing LLM response streams.

  Provides utilities for:
    * Detecting stream intent (tool call vs content)
    * Extracting tool calls from fragmented stream chunks
    * Consuming streams into text

  ## Example

      {:tool_call, consumed, remaining} = BranchedLLM.LLM.StreamParser.consume_until_intent(stream)
      tool_calls = BranchedLLM.LLM.StreamParser.extract_tool_calls(consumed ++ Enum.to_list(remaining))

  """
  alias ReqLLM.StreamChunk
  alias ReqLLM.ToolCall

  @type stream_chunk :: StreamChunk.t()
  @type intent_result ::
          {:tool_call, list(stream_chunk()), Enumerable.t()}
          | {:content, list(stream_chunk()), Enumerable.t()}
          | {:empty, list(stream_chunk())}

  @doc """
  Peeks at the stream to determine if the LLM is starting a tool call or content.

  Returns one of:
    * `{:tool_call, consumed_chunks, remaining_stream}`
    * `{:content, consumed_chunks, remaining_stream}`
    * `{:empty, consumed_chunks}`
  """
  @spec consume_until_intent(Enumerable.t()) :: intent_result()
  def consume_until_intent(stream) do
    Enum.reduce_while(stream, {[], stream}, fn chunk, {acc, _} ->
      cond do
        chunk.type == :tool_call ->
          {:halt, {:tool_call, Enum.reverse([chunk | acc]), stream}}

        chunk.type == :content and (chunk.text != nil and chunk.text != "") ->
          {:halt, {:content, Enum.reverse([chunk | acc]), stream}}

        true ->
          # Keep looking (meta chunks, empty content chunks, etc.)
          {:cont, {[chunk | acc], stream}}
      end
    end)
    |> case do
      {acc, _} -> {:empty, Enum.reverse(acc)}
      result -> result
    end
  end

  @doc """
  Extracts and reassembles tool calls from a list of chunks, handling fragments.
  """
  @spec extract_tool_calls(list(stream_chunk())) :: list(ToolCall.t())
  def extract_tool_calls(chunks) do
    base_calls = Enum.filter(chunks, fn chunk -> Map.get(chunk, :type) == :tool_call end)
    fragments = extract_fragments(chunks)

    # Merge and deduplicate by ID
    base_calls
    |> Enum.map(fn call -> build_tool_call(call, fragments) end)
    |> Enum.uniq_by(fn tc -> tc.id end)
  end

  @doc """
  Reduces a stream of chunks into a single text string.
  """
  @spec consume_to_text(Enumerable.t()) :: String.t()
  def consume_to_text(stream) do
    stream
    |> Enum.reduce("", &accumulate_text/2)
  end

  @doc """
  Reducer for accumulating text content from chunks.
  """
  @spec accumulate_text(stream_chunk(), String.t()) :: String.t()
  def accumulate_text(chunk, acc) do
    if content_chunk?(chunk) do
      acc <> chunk.text
    else
      acc
    end
  end

  @spec content_chunk?(stream_chunk()) :: boolean()
  def content_chunk?(chunk), do: chunk.type == :content

  ## Private Helpers

  defp extract_fragments(chunks) do
    chunks
    |> Enum.filter(fn chunk ->
      Map.get(chunk, :type) == :meta and
        match?(%{tool_call_args: %{index: _}}, Map.get(chunk, :metadata, %{}))
    end)
    |> Enum.group_by(fn chunk ->
      meta = Map.get(chunk, :metadata, %{})
      args = Map.get(meta, :tool_call_args, %{})
      Map.get(args, :index)
    end)
    |> Map.new(fn {idx, meta_chunks} ->
      json =
        Enum.map_join(meta_chunks, "", fn chunk ->
          meta = Map.get(chunk, :metadata, %{})
          args = Map.get(meta, :tool_call_args, %{})
          Map.get(args, :fragment, "")
        end)

      {idx, json}
    end)
  end

  defp build_tool_call(call, fragments) do
    metadata = Map.get(call, :metadata, %{})
    index = Map.get(metadata, :index) || Map.get(call, :index)
    id = Map.get(metadata, :id) || Map.get(call, :id)
    name = Map.get(call, :name) || Map.get(metadata, :name)

    arguments_json =
      case Map.get(fragments, index) do
        nil ->
          extract_arguments_from_call(call, metadata)

        json ->
          json
      end

    ToolCall.new(id, name, arguments_json)
  end

  defp extract_arguments_from_call(call, metadata) do
    call_args = Map.get(call, :arguments) || Map.get(metadata, :arguments)

    cond do
      is_binary(call_args) -> call_args
      is_map(call_args) -> Jason.encode!(call_args)
      true -> "{}"
    end
  end
end
