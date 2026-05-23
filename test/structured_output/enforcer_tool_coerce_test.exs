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
        Enum.find(result.tools, fn t ->
          t["function"]["name"] == "__structured_output__"
        end)

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
  end

  describe "extract_response/2" do
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

    test "extracts JSON from text when no tool calls" do
      assert {:ok, %{"key" => "val"}} =
               ToolCoerce.extract_response(%{text: ~s({"key": "val"})}, %{})
    end
  end
end
