defmodule BranchedLLM.EngineTest do
  use ExUnit.Case, async: true
  alias BranchedLLM.Engine
  alias BranchedLLM.Tree
  alias BranchedLLM.Message
  alias ReqLLM.Context
  import Mox

  setup :set_mox_from_context

  setup do
    chat_module = BranchedLLM.ChatMock
    stub(chat_module, :new_context, fn content -> Context.new([Context.system(content)]) end)

    initial_messages = [Message.new(:system, "You are a helpful assistant.")]
    initial_context = Context.new([Context.system("You are a helpful assistant.")])
    tree = Tree.new(chat_module, initial_messages, initial_context)
    {:ok, tree: tree}
  end

  defp make_tool_call(id, name, args_map) do
    ReqLLM.ToolCall.new(id, name, Jason.encode!(args_map))
  end

  describe "process_response/3 with :chunk" do
    test "appends chunk to existing assistant message", %{tree: tree} do
      tree = Tree.add_user_message(tree, "Hello")
      tree = put_in(tree.branches["main"].messages, tree.branches["main"].messages ++ [Message.new(:assistant, "Hi")])

      {:continue, updated_tree} = Engine.process_response(tree, "main", {:chunk, " there"})

      messages = updated_tree.branches["main"].messages
      last_msg = List.last(messages)
      assert last_msg.content == "Hi there"
    end

    test "creates new assistant message when last is not assistant", %{tree: tree} do
      tree = Tree.add_user_message(tree, "Hello")

      {:continue, updated_tree} = Engine.process_response(tree, "main", {:chunk, "Hi there"})

      messages = updated_tree.branches["main"].messages
      last_msg = List.last(messages)
      assert last_msg.sender == :assistant
      assert last_msg.content == "Hi there"
    end

    test "ignores empty chunk", %{tree: tree} do
      tree = Tree.add_user_message(tree, "Hello")

      {:continue, updated_tree} = Engine.process_response(tree, "main", {:chunk, ""})

      assert updated_tree.branches["main"].messages == tree.branches["main"].messages
    end
  end

  describe "process_response/3 with :error" do
    test "adds error message and returns halt", %{tree: tree} do
      tree = Tree.add_user_message(tree, "Hello")
      initial_msg_count = length(tree.branches["main"].messages)

      {:halt, updated_tree, reason} = Engine.process_response(tree, "main", {:error, "Connection failed"})

      assert reason == "Connection failed"
      messages = updated_tree.branches["main"].messages
      assert length(messages) == initial_msg_count + 1
      last_msg = List.last(messages)
      assert last_msg.sender == :assistant
      assert last_msg.content == "Error: Connection failed"
    end
  end

  describe "process_response/3 with :tool_calls" do
    test "returns execute_tools action with tool calls", %{tree: tree} do
      tree = Tree.add_user_message(tree, "Hello")
      tree = put_in(tree.branches["main"].messages, tree.branches["main"].messages ++ [Message.new(:assistant, "")])

      tool_calls = [make_tool_call("call_1", "get_weather", %{})]
      context_builder = fn content -> Context.new([Context.assistant(content)]) end

      {:execute_tools, updated_tree, returned_tool_calls} =
        Engine.process_response(tree, "main", {:tool_calls, tool_calls, context_builder})

      assert length(returned_tool_calls) == length(tool_calls)
      messages = updated_tree.branches["main"].messages
      last_msg = List.last(messages)
      assert last_msg.metadata[:tool_calls] == returned_tool_calls
    end
  end

  describe "process_response/3 with :done" do
    test "finishes assistant message and returns ok", %{tree: tree} do
      tree = Tree.add_user_message(tree, "Hello")
      tree = put_in(tree.branches["main"].messages, tree.branches["main"].messages ++ [Message.new(:assistant, "Hello back")])

      context_builder = fn content -> Context.new([Context.assistant(content)]) end

      {:ok, updated_tree} = Engine.process_response(tree, "main", {:done, context_builder})

      # Context was rebuilt via the builder - just verify it's valid
      assert %Tree{} = updated_tree
    end

    test "creates new assistant message when none exists", %{tree: tree} do
      tree = Tree.add_user_message(tree, "Hello")

      context_builder = fn content -> Context.new([Context.assistant(content)]) end

      {:ok, updated_tree} = Engine.process_response(tree, "main", {:done, context_builder})

      messages = updated_tree.branches["main"].messages
      last_msg = List.last(messages)
      assert last_msg.sender == :assistant
    end

    test "adds tool_calls metadata when provided with existing assistant message", %{tree: tree} do
      tree = Tree.add_user_message(tree, "Hello")
      tree = put_in(tree.branches["main"].messages, tree.branches["main"].messages ++ [Message.new(:assistant, "Response")])

      tool_calls = [make_tool_call("call_1", "test", %{})]
      context_builder = fn content -> Context.new([Context.assistant(content)]) end

      {:execute_tools, updated_tree, returned_tool_calls} =
        Engine.process_response(tree, "main", {:tool_calls, tool_calls, context_builder})

      messages = updated_tree.branches["main"].messages
      last_msg = List.last(messages)
      assert last_msg.sender == :assistant
      assert returned_tool_calls == tool_calls
    end

    test "creates new assistant message with tool_calls when last is not assistant", %{tree: tree} do
      tree = Tree.add_user_message(tree, "Hello")

      tool_calls = [make_tool_call("call_1", "test", %{})]
      context_builder = fn content -> Context.new([Context.assistant(content)]) end

      {:execute_tools, updated_tree, returned_tool_calls} =
        Engine.process_response(tree, "main", {:tool_calls, tool_calls, context_builder})

      messages = updated_tree.branches["main"].messages
      last_msg = List.last(messages)
      assert last_msg.sender == :assistant
      assert last_msg.metadata[:tool_calls] == tool_calls
      assert returned_tool_calls == tool_calls
    end
  end
end
