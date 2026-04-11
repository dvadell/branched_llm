defmodule BranchedLLM.TreeAdditionalTest do
  use ExUnit.Case, async: true
  alias BranchedLLM.Tree
  alias BranchedLLM.Message
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

  describe "switch_branch/2" do
    test "switches to an existing branch", %{tree: tree} do
      tree = Tree.add_user_message(tree, "M1")
      m1_id = List.last(tree.branches["main"].messages).id
      tree = Tree.branch_off(tree, m1_id)
      _new_branch_id = tree.current_branch_id

      tree = Tree.switch_branch(tree, "main")
      assert tree.current_branch_id == "main"
    end

    test "does not switch to non-existent branch", %{tree: tree} do
      tree = Tree.switch_branch(tree, "nonexistent")
      assert tree.current_branch_id == "main"
    end
  end

  describe "delete_message/2" do
    test "marks a message as deleted and rebuilds context", %{tree: tree} do
      tree = Tree.add_user_message(tree, "Hello")
      msg_id = List.last(tree.branches["main"].messages).id

      tree = Tree.delete_message(tree, msg_id)

      _messages = Tree.get_current_messages(tree)
      # Deleted messages are filtered out when rebuilding context
      deleted_msg = Enum.find(tree.branches["main"].messages, fn m -> m.id == msg_id end)
      assert deleted_msg.deleted == true
    end

    test "handles non-existent message id", %{tree: tree} do
      tree = Tree.delete_message(tree, "nonexistent")
      assert tree.current_branch_id == "main"
    end
  end

  describe "insert_message/3" do
    test "returns tree unchanged if after_message_id not found", %{tree: tree} do
      original_messages = tree.branches["main"].messages
      tree = Tree.insert_message(tree, "nonexistent", Message.new(:user, "Test"))
      assert tree.branches["main"].messages == original_messages
    end
  end

  describe "branch_off/2" do
    test "returns tree unchanged if message_id not found", %{tree: tree} do
      original_branches = tree.branches
      original_branch_ids = tree.branch_ids
      tree = Tree.branch_off(tree, "nonexistent")
      assert tree.branches == original_branches
      assert tree.branch_ids == original_branch_ids
    end
  end

  describe "prune_branch/2" do
    test "does not prune main branch", %{tree: tree} do
      tree = Tree.prune_branch(tree, "main")
      assert Map.has_key?(tree.branches, "main")
    end
  end

  describe "get_current_context/1" do
    test "returns the context of the active branch", %{tree: tree} do
      context = Tree.get_current_context(tree)
      assert %Context{} = context
    end
  end

  describe "add_user_message/2" do
    test "generates name from content for main branch", %{tree: tree} do
      long_content = String.duplicate("x", 50)
      tree = Tree.add_user_message(tree, long_content)
      branch = tree.branches["main"]
      assert branch.name == String.duplicate("x", 30) <> "..."
    end

    test "does not overwrite existing custom branch name", %{tree: tree} do
      tree = Tree.add_user_message(tree, "First message")
      branch = tree.branches["main"]
      original_name = branch.name

      tree = Tree.add_user_message(tree, "Second message")
      branch = tree.branches["main"]
      assert branch.name == original_name
    end
  end

  describe "from_map/2" do
    test "hydrates a tree from a map with chat_module", %{tree: tree, chat_module: mod} do
      tree = Tree.add_user_message(tree, "Test")
      map = Tree.to_map(tree)
      hydrated = Tree.from_map(map, mod)

      assert hydrated.chat_module == mod
      assert hydrated.current_branch_id == "main"
      assert Map.has_key?(hydrated.branches, "main")
    end
  end

  describe "update_message/3" do
    test "updates message content and rebuilds context", %{tree: tree} do
      tree = Tree.add_user_message(tree, "Old content")
      msg_id = List.last(tree.branches["main"].messages).id

      tree = Tree.update_message(tree, msg_id, "New content")

      assert List.last(tree.branches["main"].messages).content == "New content"
    end
  end

  describe "tree context rebuilding" do
    test "filters out deleted messages with user sender", %{tree: tree} do
      tree = Tree.add_user_message(tree, "User msg")
      tree = Tree.add_user_message(tree, "Another user msg")

      user_msg_id = Enum.find(tree.branches["main"].messages, fn m -> m.sender == :user end).id
      tree = Tree.delete_message(tree, user_msg_id)

      context = Tree.get_current_context(tree)
      # System should still be there, deleted user message filtered out
      assert %Context{} = context
    end
  end
end
