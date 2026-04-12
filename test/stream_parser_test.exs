defmodule BranchedLLM.LLM.StreamParserTest do
  use ExUnit.Case, async: true
  alias BranchedLLM.LLM.StreamParser

  describe "consume_until_intent/1" do
    test "detects tool call intent" do
      stream =
        Stream.map(
          [
            ReqLLM.StreamChunk.text(""),
            ReqLLM.StreamChunk.tool_call("calc", %{})
          ],
          & &1
        )

      {:tool_call, consumed, _remaining} = StreamParser.consume_until_intent(stream)

      assert Enum.any?(consumed, fn c -> c.type == :tool_call end)
    end

    test "detects content intent" do
      stream =
        Stream.map(
          [
            ReqLLM.StreamChunk.text(""),
            ReqLLM.StreamChunk.text("Hello")
          ],
          & &1
        )

      {:content, consumed, _remaining} = StreamParser.consume_until_intent(stream)

      assert Enum.any?(consumed, fn c -> c.type == :content and c.text != "" end)
    end

    test "returns empty for empty stream" do
      stream = Stream.map([], & &1)

      {:empty, _consumed} = StreamParser.consume_until_intent(stream)
    end
  end

  describe "consume_to_text/1" do
    test "concatenates all content chunks" do
      stream = Stream.map(["Hello", ", ", "world", "!"], &ReqLLM.StreamChunk.text/1)

      result = StreamParser.consume_to_text(stream)

      assert result == "Hello, world!"
    end
  end

  describe "accumulate_text/2" do
    test "accumulates content chunks" do
      acc = StreamParser.accumulate_text(ReqLLM.StreamChunk.text("Hello"), "")
      acc = StreamParser.accumulate_text(ReqLLM.StreamChunk.text(" world"), acc)

      assert acc == "Hello world"
    end

    test "ignores non-content chunks" do
      chunk = ReqLLM.StreamChunk.meta(%{finish_reason: "stop"})

      result = StreamParser.accumulate_text(chunk, "existing")

      assert result == "existing"
    end
  end

  describe "extract_tool_calls/1" do
    test "extracts tool calls from chunks" do
      chunks = [
        ReqLLM.StreamChunk.tool_call("calculator", %{"expression" => "2+2"})
      ]

      result = StreamParser.extract_tool_calls(chunks)

      assert length(result) == 1
      tool_call = List.first(result)
      assert ReqLLM.ToolCall.name(tool_call) == "calculator"
    end

    test "returns empty list for no tool calls" do
      chunks = [ReqLLM.StreamChunk.text("Hello"), ReqLLM.StreamChunk.text(" world")]

      result = StreamParser.extract_tool_calls(chunks)

      assert result == []
    end

    test "deduplicates tool calls by ID" do
      call1 = ReqLLM.StreamChunk.tool_call("calc", %{"expr" => "1+1"})
      call2 = ReqLLM.StreamChunk.tool_call("calc", %{"expr" => "2+2"})

      result = StreamParser.extract_tool_calls([call1, call2])

      assert length(result) == 2
    end

    test "extracts arguments from map arguments" do
      chunks = [
        ReqLLM.StreamChunk.tool_call("weather", %{"location" => "NYC"})
      ]

      result = StreamParser.extract_tool_calls(chunks)
      tool_call = List.first(result)

      assert ReqLLM.ToolCall.name(tool_call) == "weather"
      args = ReqLLM.ToolCall.args_map(tool_call)
      assert args["location"] == "NYC"
    end

    test "extracts arguments from meta fragments" do
      meta_chunk = %ReqLLM.StreamChunk{
        type: :meta,
        metadata: %{
          tool_call_args: %{
            index: 0,
            fragment: "{\"location\":\"NYC\"}"
          }
        }
      }

      tool_chunk = ReqLLM.StreamChunk.tool_call("weather", %{})

      result = StreamParser.extract_tool_calls([tool_chunk, meta_chunk])

      assert length(result) == 1
    end

    test "handles nil arguments with fallback" do
      chunk = %ReqLLM.StreamChunk{type: :tool_call, name: "test", arguments: nil}

      result = StreamParser.extract_tool_calls([chunk])

      assert length(result) == 1
    end

    test "extracts arguments from string arguments" do
      chunk = %ReqLLM.StreamChunk{type: :tool_call, name: "test", arguments: "{\"a\":1}"}

      result = StreamParser.extract_tool_calls([chunk])

      assert length(result) == 1
    end

    test "handles tool call with metadata index and id" do
      chunk = %ReqLLM.StreamChunk{
        type: :tool_call,
        name: "weather",
        arguments: %{"city" => "NYC"},
        metadata: %{index: 0, id: "call_xyz"}
      }

      result = StreamParser.extract_tool_calls([chunk])

      assert length(result) == 1
      tool_call = List.first(result)
      assert ReqLLM.ToolCall.name(tool_call) == "weather"
    end

    test "handles meta chunks with tool_call_args fragment" do
      meta_chunk = %ReqLLM.StreamChunk{
        type: :meta,
        metadata: %{
          tool_call_args: %{
            index: 0,
            fragment: "{\"expr\":\"1+1\"}"
          }
        }
      }

      tool_chunk = %ReqLLM.StreamChunk{
        type: :tool_call,
        name: "calc",
        arguments: nil
      }

      result = StreamParser.extract_tool_calls([tool_chunk, meta_chunk])

      assert length(result) == 1
      tool_call = List.first(result)
      assert ReqLLM.ToolCall.name(tool_call) == "calc"
    end

    test "handles empty tool arguments fallback" do
      chunk = %ReqLLM.StreamChunk{type: :tool_call, name: "test", arguments: nil}

      result = StreamParser.extract_tool_calls([chunk])

      tool_call = List.first(result)
      args = ReqLLM.ToolCall.args_map(tool_call)
      assert args == %{}
    end

    test "handles tool call with name in metadata instead of chunk" do
      chunk = %ReqLLM.StreamChunk{
        type: :tool_call,
        name: nil,
        arguments: nil,
        metadata: %{name: "weather_from_meta"}
      }

      result = StreamParser.extract_tool_calls([chunk])

      assert length(result) == 1
      tool_call = List.first(result)
      assert ReqLLM.ToolCall.name(tool_call) == "weather_from_meta"
    end

    test "extracts arguments from map arguments via Jason encoding" do
      chunk = %ReqLLM.StreamChunk{
        type: :tool_call,
        name: "test",
        arguments: %{"key" => "value"}
      }

      result = StreamParser.extract_tool_calls([chunk])

      assert length(result) == 1
    end

    test "content_chunk? returns false for non-content chunks" do
      refute StreamParser.content_chunk?(%{type: :tool_call})
      refute StreamParser.content_chunk?(%{type: :meta})
      refute StreamParser.content_chunk?(%{type: :thinking})
    end

    test "extracts arguments from meta fragment when index matches" do
      # Tool call chunk with index in metadata
      tool_chunk = %ReqLLM.StreamChunk{
        type: :tool_call,
        name: "calc",
        arguments: nil,
        metadata: %{index: 0}
      }

      # Meta chunk with matching index and fragment
      meta_chunk = %ReqLLM.StreamChunk{
        type: :meta,
        metadata: %{
          tool_call_args: %{
            index: 0,
            fragment: "{\"expression\":\"1+1\"}"
          }
        }
      }

      result = StreamParser.extract_tool_calls([tool_chunk, meta_chunk])

      assert length(result) == 1
      tool_call_result = List.first(result)
      assert ReqLLM.ToolCall.name(tool_call_result) == "calc"
      # The arguments should come from the meta fragment, not the tool_call chunk
      args = ReqLLM.ToolCall.args_map(tool_call_result)
      assert args["expression"] == "1+1"
    end
  end
end
