defmodule BranchedLLM.EngineTest do
  use ExUnit.Case, async: true
  alias BranchedLLM.Engine
  alias BranchedLLM.Tree
  alias BranchedLLM.Message
  alias ReqLLM.Context

  setup do
    chat_module = BranchedLLM.ChatMock
    initial_messages = [Message.new(:system, "System")]
    initial_context = Context.new([Context.system("System")])
    tree = Tree.new(chat_module, initial_messages, initial_context)
    {:ok, tree: tree}
  end

  test "process_response :chunk appends content", %{tree: tree} do
    {:continue, updated_tree} = Engine.process_response(tree, "main", {:chunk, "Hello"})
    messages = Tree.get_current_messages(updated_tree)
    assert List.last(messages).content == "Hello"

    {:continue, updated_tree2} = Engine.process_response(updated_tree, "main", {:chunk, " world"})
    messages2 = Tree.get_current_messages(updated_tree2)
    assert List.last(messages2).content == "Hello world"
  end

  test "process_response :error adds error message", %{tree: tree} do
    {:halt, updated_tree, reason} = Engine.process_response(tree, "main", {:error, "timeout"})
    assert reason == "timeout"
    messages = Tree.get_current_messages(updated_tree)
    assert String.contains?(List.last(messages).content, "Error: timeout")
  end

  test "process_response :done finalizes message", %{tree: tree} do
    # Add a chunk first
    {:continue, tree} = Engine.process_response(tree, "main", {:chunk, "Final answer"})

    context_builder = fn _content -> Context.new([Context.assistant("Final answer")]) end
    {:ok, updated_tree} = Engine.process_response(tree, "main", {:done, context_builder})

    assert Tree.get_current_context(updated_tree).messages != []
  end

  test "process_response :tool_calls marks metadata", %{tree: tree} do
    tool_calls = [%{id: "1", function: %{name: "calc", arguments: "{}"}}]
    context_builder = fn _content -> Context.new([]) end

    {:execute_tools, updated_tree, calls} =
      Engine.process_response(tree, "main", {:tool_calls, tool_calls, context_builder})

    assert calls == tool_calls
    last_msg = List.last(Tree.get_current_messages(updated_tree))
    assert Map.get(last_msg.metadata, :tool_calls) == tool_calls
  end
end
