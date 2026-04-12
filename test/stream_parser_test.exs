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
  end
end
