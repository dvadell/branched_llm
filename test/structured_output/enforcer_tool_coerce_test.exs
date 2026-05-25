defmodule BranchedLLM.StructuredOutput.EnforcerToolCoerceTest do
  use ExUnit.Case, async: true

  alias BranchedLLM.StructuredOutput.Enforcer.ToolCoerce

  describe "prepare_request/2" do
    test "adds synthetic tool to tools list" do
      schema = %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}},
        "required" => ["name"]
      }

      request = %{tools: [%{"type" => "function", "function" => %{"name" => "other_tool"}}]}

      result = ToolCoerce.prepare_request(request, schema)

      assert length(result.tools) == 2

      synthetic_tool =
        Enum.find(result.tools, fn t -> t["function"]["name"] == "__structured_output__" end)

      assert synthetic_tool != nil
      assert synthetic_tool["function"]["parameters"] == schema
    end

    test "sets tool_choice to force structured output" do
      schema = %{"type" => "object", "properties" => %{}}
      request = %{tools: []}

      result = ToolCoerce.prepare_request(request, schema)

      assert result.tool_choice == %{
               "type" => "function",
               "function" => %{"name" => "__structured_output__"}
             }
    end

    test "works with empty tools list" do
      schema = %{"type" => "object", "properties" => %{}}

      result = ToolCoerce.prepare_request(%{tools: []}, schema)

      assert length(result.tools) == 1
    end

    test "works without existing tools key" do
      schema = %{"type" => "object", "properties" => %{}}

      result = ToolCoerce.prepare_request(%{}, schema)

      assert length(result.tools) == 1
    end
  end

  describe "extract_response/2 with tool_calls" do
    test "extracts structured data from tool call arguments" do
      tool_call =
        ReqLLM.ToolCall.new("call_1", "__structured_output__", ~s({"invoice": "INV-001"}))

      assert {:ok, %{"invoice" => "INV-001"}} =
               ToolCoerce.extract_response(%{tool_calls: [tool_call]}, %{})
    end

    test "returns error when structured output tool not found" do
      tool_call = ReqLLM.ToolCall.new("call_1", "other_tool", ~s({}))

      assert {:error, :structured_output_tool_not_found} =
               ToolCoerce.extract_response(%{tool_calls: [tool_call]}, %{})
    end

    test "returns empty map when tool call has nil arguments" do
      tool_call = %ReqLLM.ToolCall{
        id: "call_1",
        type: "function",
        function: %{name: "__structured_output__", arguments: nil}
      }

      result = ToolCoerce.extract_response(%{tool_calls: [tool_call]}, %{})
      assert {:ok, _} = result
    end
  end

  describe "extract_response/2 with text" do
    test "extracts JSON from text when no tool calls" do
      assert {:ok, %{"key" => "val"}} =
               ToolCoerce.extract_response(%{text: ~s({"key": "val"})}, %{})
    end

    test "returns error for invalid JSON in text" do
      assert {:error, :invalid_json} = ToolCoerce.extract_response(%{text: "bad"}, %{})
    end

    test "returns error when text decodes to non-map JSON" do
      assert {:error, :invalid_json} =
               ToolCoerce.extract_response(%{text: ~s([1, 2, 3])}, %{})
    end
  end

  describe "extract_response/2 with unsupported format" do
    test "returns error for non-matching response format" do
      assert {:error, :unsupported_response_format} = ToolCoerce.extract_response(123, %{})
    end

    test "returns error for atom response" do
      assert {:error, :unsupported_response_format} = ToolCoerce.extract_response(:something, %{})
    end
  end
end
