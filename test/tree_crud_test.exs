defmodule BranchedLLM.TreeCRUDTest do
  use ExUnit.Case, async: true
  alias BranchedLLM.Message
  alias BranchedLLM.Tree
  alias ReqLLM.Context
  import Mox

  setup :set_mox_from_context

  setup do
    chat_module = BranchedLLM.ChatMock
    stub(chat_module, :new_context, fn content -> Context.new([Context.system(content)]) end)

    initial_messages = [Message.new(:system, "You are a tutor.")]
    initial_context = Context.new([Context.system("You are a tutor.")])

    tree = Tree.new(chat_module, initial_messages, initial_context)
    {:ok, tree: tree, chat_module: chat_module}
  end

  test "initializes with main branch", %{tree: tree} do
    assert tree.current_branch_id == "main"
    assert Map.has_key?(tree.branches, "main")
    assert length(tree.branches["main"].messages) == 1
  end

  test "add_user_message updates current branch", %{tree: tree} do
    tree = Tree.add_user_message(tree, "Hello")
    messages = Tree.get_current_messages(tree)
    assert length(messages) == 2
    assert List.last(messages).content == "Hello"
  end

  test "update_message rebuilds context", %{tree: tree, chat_module: mod} do
    tree = Tree.add_user_message(tree, "Old content")
    msg_id = List.last(tree.branches["main"].messages).id
    expect(mod, :new_context, 1, fn _ -> Context.new([]) end)
    tree = Tree.update_message(tree, msg_id, "New content")
    assert List.last(tree.branches["main"].messages).content == "New content"
  end

  test "insert_message adds message in the middle", %{tree: tree, chat_module: mod} do
    tree = Tree.add_user_message(tree, "M1")
    m1_id = List.last(tree.branches["main"].messages).id
    tree = Tree.add_user_message(tree, "M3")
    m2 = Message.new(:user, "M2")
    expect(mod, :new_context, 1, fn _ -> Context.new([]) end)
    tree = Tree.insert_message(tree, m1_id, m2)
    messages = Tree.get_current_messages(tree)
    assert length(messages) == 4
    assert Enum.at(messages, 2).content == "M2"
  end
end
