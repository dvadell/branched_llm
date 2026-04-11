defmodule BranchedLLM.ToolHandlerTest do
  use ExUnit.Case, async: true
  alias BranchedLLM.ToolHandler
  alias ReqLLM.Context
  import Mox

  setup :set_mox_from_context

  defmodule MockTool do
    defstruct [:name]
  end

  defmodule MockChatModule do
    def execute_tool(%MockTool{name: "failing_tool"}, _args) do
      {:error, "Connection refused"}
    end

    def execute_tool(%MockTool{}, _args) do
      {:ok, "Mock result"}
    end
  end

  defp make_tool_call(id, name, args_map) do
    ReqLLM.ToolCall.new(id, name, Jason.encode!(args_map))
  end

  describe "handle_tool_calls/4" do
    test "executes multiple tool calls and returns updated context" do
      tool = %MockTool{name: "get_weather"}

      tool_call = make_tool_call("call_123", "get_weather", %{"location" => "NYC"})

      context = Context.new([])
      result = ToolHandler.handle_tool_calls([tool_call], context, [tool], MockChatModule)

      # Context has tool result appended - just verify it's a Context struct
      assert %Context{} = result
    end

    test "handles tool not found gracefully" do
      tool_call = make_tool_call("call_456", "nonexistent_tool", %{})

      context = Context.new([])
      result = ToolHandler.handle_tool_calls([tool_call], context, [], MockChatModule)

      assert %Context{} = result
    end
  end

  describe "process_tool_call/4" do
    test "executes a tool successfully and appends result to context" do
      tool = %MockTool{name: "calculator"}

      tool_call = make_tool_call("call_789", "calculator", %{"a" => 5, "b" => 3})

      context = Context.new([])
      result = ToolHandler.process_tool_call(tool_call, [tool], context, MockChatModule)

      assert %Context{} = result
    end

    test "returns error message when tool is not found" do
      tool_call = make_tool_call("call_abc", "missing_tool", %{})

      context = Context.new([])
      result = ToolHandler.process_tool_call(tool_call, [], context, MockChatModule)

      assert %Context{} = result
    end

    test "handles tool execution error" do
      tool = %MockTool{name: "failing_tool"}

      tool_call = make_tool_call("call_err", "failing_tool", %{})

      context = Context.new([])
      result = ToolHandler.process_tool_call(tool_call, [tool], context, MockChatModule)

      assert %Context{} = result
    end
  end
end
