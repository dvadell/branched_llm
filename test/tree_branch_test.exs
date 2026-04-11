defmodule BranchedLLM.TreeBranchTest do
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

  test "branch_off creates a new branch from a specific message", %{tree: tree} do
    tree = Tree.add_user_message(tree, "M1")
    m1_id = List.last(tree.branches["main"].messages).id
    tree = Tree.branch_off(tree, m1_id)
    assert tree.current_branch_id != "main"
    assert length(tree.branches[tree.current_branch_id].messages) == 2
  end

  test "prune_branch removes branch and children", %{tree: tree} do
    tree = Tree.add_user_message(tree, "M1")
    m1_id = List.last(tree.branches["main"].messages).id
    tree = Tree.branch_off(tree, m1_id)
    child_branch_id = tree.current_branch_id
    tree = Tree.prune_branch(tree, child_branch_id)
    refute Map.has_key?(tree.branches, child_branch_id)
    assert tree.current_branch_id == "main"
  end

  test "serialization to_map and from_map", %{tree: tree, chat_module: mod} do
    tree = Tree.add_user_message(tree, "Serialize me")
    map = Tree.to_map(tree)
    assert is_map(map)
    hydrated = Tree.from_map(map, mod)
    assert hydrated.current_branch_id == "main"
  end
end
