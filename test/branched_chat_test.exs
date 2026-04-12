defmodule BranchedLLM.BranchedChatTest do
  use ExUnit.Case, async: true
  import Mox
  alias BranchedLLM.{BranchedChat, Message}
  alias ReqLLM.Context

  setup :set_mox_from_context

  defp mock_context do
    Context.new([Context.system("test")])
  end

  defp mock_chat_module, do: BranchedLLM.ChatMock

  describe "new/3" do
    test "creates a branched chat with a main branch" do
      chat = BranchedChat.new(mock_chat_module(), [], mock_context())

      assert chat.current_branch_id == "main"
      assert chat.branch_ids == ["main"]
      assert chat.child_branches == %{}
      assert chat.chat_module == mock_chat_module()
      assert chat.branches["main"].name == "Main Conversation"
      assert chat.branches["main"].messages == []
      assert chat.branches["main"].pending_messages == []
      assert chat.branches["main"].active_task == nil
    end
  end

  describe "add_user_message/2" do
    test "adds a user message to the current branch" do
      chat = BranchedChat.new(mock_chat_module(), [], mock_context())
      chat = BranchedChat.add_user_message(chat, "Hello!")

      messages = BranchedChat.get_current_messages(chat)
      assert length(messages) == 1
      assert List.last(messages).role == :user
      assert List.last(messages).content == "Hello!"
    end

    test "sets branch name from first user message on empty-named branch" do
      messages = [Message.new(:system, "System")]
      stub(BranchedLLM.ChatMock, :reset_context, fn _ctx -> mock_context() end)

      chat = BranchedChat.new(mock_chat_module(), messages, mock_context())
      chat = BranchedChat.branch_off(chat, List.first(messages).id)
      long_content = String.duplicate("a", 50)
      chat = BranchedChat.add_user_message(chat, long_content)

      assert chat.branches[chat.current_branch_id].name == String.duplicate("a", 30) <> "..."
    end
  end

  describe "append_chunk/3" do
    test "appends chunks to build assistant message" do
      chat = BranchedChat.new(mock_chat_module(), [], mock_context())
      chat = BranchedChat.append_chunk(chat, "main", "Hello")
      chat = BranchedChat.append_chunk(chat, "main", " world")

      messages = BranchedChat.get_current_messages(chat)
      assert length(messages) == 1
      assert List.last(messages).role == :assistant
      assert List.last(messages).content == "Hello world"
    end

    test "clears tool status on chunk append" do
      chat = BranchedChat.new(mock_chat_module(), [], mock_context())
      chat = BranchedChat.set_tool_status(chat, "main", "Thinking...")
      chat = BranchedChat.append_chunk(chat, "main", "Hi")

      assert chat.branches["main"].tool_status == nil
    end

    test "ignores empty chunks" do
      chat = BranchedChat.new(mock_chat_module(), [], mock_context())
      chat = BranchedChat.append_chunk(chat, "main", "")

      messages = BranchedChat.get_current_messages(chat)
      assert messages == []
    end
  end

  describe "finish_ai_response/3" do
    test "finalizes assistant response with new context" do
      chat = BranchedChat.new(mock_chat_module(), [], mock_context())
      chat = BranchedChat.add_user_message(chat, "Hi")
      chat = BranchedChat.append_chunk(chat, "main", "Hello!")
      chat = BranchedChat.set_active_task(chat, "main", self(), "Hi")

      builder = fn text -> Context.new([Context.assistant(text)]) end
      chat = BranchedChat.finish_ai_response(chat, "main", builder)

      assert chat.branches["main"].active_task == nil
      assert chat.branches["main"].current_user_message == nil
      assert chat.branches["main"].tool_status == nil
    end
  end

  describe "add_error_message/3" do
    test "appends error message to branch" do
      chat = BranchedChat.new(mock_chat_module(), [], mock_context())
      chat = BranchedChat.add_error_message(chat, "main", "Something went wrong")

      messages = BranchedChat.get_current_messages(chat)
      assert List.last(messages).role == :assistant
      assert List.last(messages).content == "Something went wrong"
    end
  end

  describe "branch_off/2" do
    test "creates a new branch from a message" do
      messages = [
        Message.new(:system, "System"),
        Message.new(:user, "Hello"),
        Message.new(:assistant, "Hi!")
      ]

      chat = BranchedChat.new(mock_chat_module(), messages, mock_context())
      user_msg_id = Enum.at(messages, 1).id

      stub(BranchedLLM.ChatMock, :reset_context, fn _ctx -> mock_context() end)

      chat = BranchedChat.branch_off(chat, user_msg_id)

      assert length(chat.branch_ids) == 2
      assert chat.current_branch_id != "main"
      assert chat.branches[chat.current_branch_id].parent_branch_id == "main"
      assert chat.branches[chat.current_branch_id].parent_message_id == user_msg_id
    end

    test "returns unchanged chat if message not found" do
      chat = BranchedChat.new(mock_chat_module(), [], mock_context())
      old_chat = chat

      chat = BranchedChat.branch_off(chat, "nonexistent")

      assert chat.branch_ids == old_chat.branch_ids
    end
  end

  describe "delete_message/2" do
    test "marks message as deleted and rebuilds context" do
      messages = [
        Message.new(:system, "System"),
        Message.new(:user, "Hello"),
        Message.new(:assistant, "Hi!")
      ]

      stub(BranchedLLM.ChatMock, :reset_context, fn _ctx -> mock_context() end)

      chat = BranchedChat.new(mock_chat_module(), messages, mock_context())
      msg_id = Enum.at(messages, 1).id

      chat = BranchedChat.delete_message(chat, msg_id)

      deleted_msg = Enum.find(BranchedChat.get_current_messages(chat), &(&1.id == msg_id))
      assert Message.deleted?(deleted_msg)
    end
  end

  describe "switch_branch/2" do
    test "changes the active branch" do
      messages = [Message.new(:system, "System")]
      stub(BranchedLLM.ChatMock, :reset_context, fn _ctx -> mock_context() end)

      chat = BranchedChat.new(mock_chat_module(), messages, mock_context())
      chat = BranchedChat.branch_off(chat, List.first(messages).id)
      new_branch_id = chat.current_branch_id

      chat = BranchedChat.switch_branch(chat, "main")
      assert chat.current_branch_id == "main"

      chat = BranchedChat.switch_branch(chat, new_branch_id)
      assert chat.current_branch_id == new_branch_id
    end

    test "ignores unknown branch" do
      chat = BranchedChat.new(mock_chat_module(), [], mock_context())
      old_id = chat.current_branch_id

      chat = BranchedChat.switch_branch(chat, "unknown")

      assert chat.current_branch_id == old_id
    end
  end

  describe "busy?/2" do
    test "returns true when active_task is set" do
      chat = BranchedChat.new(mock_chat_module(), [], mock_context())

      refute BranchedChat.busy?(chat, "main")

      chat = BranchedChat.set_active_task(chat, "main", self(), "Hi")
      assert BranchedChat.busy?(chat, "main")
    end
  end

  describe "clear_active_task/2" do
    test "clears active task and related fields" do
      chat = BranchedChat.new(mock_chat_module(), [], mock_context())
      chat = BranchedChat.set_active_task(chat, "main", self(), "Hi")
      chat = BranchedChat.set_tool_status(chat, "main", "Thinking...")

      chat = BranchedChat.clear_active_task(chat, "main")

      assert chat.branches["main"].active_task == nil
      assert chat.branches["main"].current_user_message == nil
      assert chat.branches["main"].tool_status == nil
    end
  end

  describe "enqueue/dequeue_message" do
    test "queues and dequeues messages" do
      chat = BranchedChat.new(mock_chat_module(), [], mock_context())
      chat = BranchedChat.enqueue_message(chat, "main", "msg1")
      chat = BranchedChat.enqueue_message(chat, "main", "msg2")

      {"msg1", chat} = BranchedChat.dequeue_message(chat, "main")
      {"msg2", chat} = BranchedChat.dequeue_message(chat, "main")
      {nil, _chat} = BranchedChat.dequeue_message(chat, "main")
    end
  end

  describe "build_tree/1" do
    test "builds hierarchical tree of branches" do
      messages = [Message.new(:system, "System")]
      stub(BranchedLLM.ChatMock, :reset_context, fn _ctx -> mock_context() end)

      chat = BranchedChat.new(mock_chat_module(), messages, mock_context())
      msg_id = List.first(messages).id

      chat = BranchedChat.branch_off(chat, msg_id)
      _child_branch_id = chat.current_branch_id

      chat = BranchedChat.add_user_message(chat, "Hi")
      child_msg = List.last(BranchedChat.get_current_messages(chat))

      chat = BranchedChat.branch_off(chat, child_msg.id)
      _grandchild_id = chat.current_branch_id

      tree = BranchedChat.build_tree(chat)

      assert length(tree) == 1
      assert List.first(tree).id == "main"
      assert length(List.first(tree).children) == 1
      assert length(List.first(List.first(tree).children).children) == 1
    end
  end

  describe "set_tool_status/3" do
    test "sets tool status for a branch" do
      chat = BranchedChat.new(mock_chat_module(), [], mock_context())
      chat = BranchedChat.set_tool_status(chat, "main", "Using calculator...")

      assert chat.branches["main"].tool_status == "Using calculator..."
    end
  end

  describe "get_current_context/1" do
    test "returns the context of the active branch" do
      ctx = mock_context()
      chat = BranchedChat.new(mock_chat_module(), [], ctx)

      assert BranchedChat.get_current_context(chat) == ctx
    end
  end
end
