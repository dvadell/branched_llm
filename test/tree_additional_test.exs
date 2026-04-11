defmodule BranchedLLM.TreeAdditionalTest do
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

    test "handles assistant messages in context rebuild", %{tree: tree} do
      tree = Tree.add_user_message(tree, "Hello")
      tree = Tree.add_user_message(tree, "World")
      _msg = List.last(tree.branches["main"].messages)

      # Update a message to trigger rebuild with assistant message present
      # First inject an assistant message, then update to trigger rebuild
      assistant_msg = Message.new(:assistant, "Assistant says hi")

      tree =
        put_in(tree.branches["main"].messages, tree.branches["main"].messages ++ [assistant_msg])

      # Now update the assistant message to trigger rebuild_context
      tree = Tree.update_message(tree, assistant_msg.id, "Updated assistant response")

      messages = tree.branches["main"].messages
      last_msg = List.last(messages)
      assert last_msg.content == "Updated assistant response"
      assert last_msg.sender == :assistant
    end

    test "handles tool and unknown sender messages in context rebuild", %{tree: tree} do
      tree = Tree.add_user_message(tree, "Hello")
      # Inject tool and unknown sender messages, then update to trigger rebuild
      tool_msg = Message.new(:tool, "tool result")
      unknown_msg = Message.new(:unknown_type, "unknown")
      new_messages = tree.branches["main"].messages ++ [tool_msg, unknown_msg]
      tree = put_in(tree.branches["main"].messages, new_messages)

      # Trigger rebuild by updating the tool message
      tree = Tree.update_message(tree, tool_msg.id, "updated tool result")

      context = Tree.get_current_context(tree)
      assert %Context{} = context
    end
  end

  describe "generate_name_from_messages" do
    test "returns empty string when no user messages exist", %{tree: tree} do
      # Branch off from system message only (index 0, which is :system sender)
      system_msg_id = List.first(tree.branches["main"].messages).id
      tree = Tree.branch_off(tree, system_msg_id)
      branch = tree.branches[tree.current_branch_id]
      # The branch only has the system message, no user messages
      assert branch.name == ""
    end
  end

  describe "prune_branch/2 with nil parent_message_id" do
    test "cleans up child branches when pruned branch has nil parent_message_id", %{tree: tree} do
      # Create a branch by branching off from system message (parent_message_id is set to system_msg_id)
      # To get nil parent_message_id, we need to manually construct via from_map
      tree = Tree.add_user_message(tree, "M1")
      m1_id = List.last(tree.branches["main"].messages).id
      tree = Tree.branch_off(tree, m1_id)
      child_id = tree.current_branch_id

      # Now manually set the child's parent_message_id to nil via map manipulation
      child_branch = tree.branches[child_id]
      updated_child = %{child_branch | parent_message_id: nil}
      tree = put_in(tree.branches[child_id], updated_child)

      # Also add a child_branches entry for nil (simulating the nil key case)
      tree = put_in(tree.child_branches[nil], [child_id])

      tree = Tree.prune_branch(tree, child_id)
      refute Map.has_key?(tree.branches, child_id)
    end
  end
end
