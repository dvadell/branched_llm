defmodule BranchedLLM.MessageTest do
  use ExUnit.Case, async: true
  alias BranchedLLM.Message

  describe "new/3" do
    test "creates a message with generated id" do
      msg = Message.new(:user, "Hello")

      assert msg.role == :user
      assert msg.sender == :user
      assert msg.content == "Hello"
      assert is_binary(msg.id)
      assert msg.metadata == %{}
    end

    test "creates a message with custom id" do
      msg = Message.new(:assistant, "Hi", "custom-id")

      assert msg.id == "custom-id"
    end

    test "creates a message with metadata" do
      msg = Message.new(:user, "Test", "id-1", %{tool_calls: [%{name: "calc"}]})

      assert msg.metadata == %{tool_calls: [%{name: "calc"}]}
    end
  end

  describe "mark_deleted/1" do
    test "marks a message as deleted" do
      msg = Message.new(:user, "Hello")
      deleted = Message.mark_deleted(msg)

      assert Message.deleted?(deleted)
      refute Message.deleted?(msg)
    end
  end

  describe "deleted?/1" do
    test "returns true for deleted messages" do
      msg = Message.new(:user, "Hello")
      assert Message.deleted?(msg) == false

      msg = Message.mark_deleted(msg)
      assert Message.deleted?(msg) == true
    end
  end

  describe "from_map/1" do
    test "converts a legacy message map with deleted flag" do
      map = %{sender: :user, content: "Hello", id: "123", deleted: true}

      msg = Message.from_map(map)

      assert msg.role == :user
      assert msg.content == "Hello"
      assert msg.id == "123"
      assert Message.deleted?(msg)
    end

    test "converts a legacy message map without deleted flag" do
      map = %{sender: :assistant, content: "Hi", id: "456"}

      msg = Message.from_map(map)

      assert msg.role == :assistant
      assert msg.content == "Hi"
      refute Message.deleted?(msg)
    end

    test "preserves existing metadata" do
      map = %{sender: :user, content: "Hello", id: "123", deleted: false, metadata: %{foo: "bar"}}

      msg = Message.from_map(map)

      assert msg.metadata == %{foo: "bar"}
    end
  end

  describe "to_map/1" do
    test "converts a message to legacy map format" do
      msg = Message.new(:user, "Hello", "id-1")

      map = Message.to_map(msg)

      assert map == %{sender: :user, content: "Hello", id: "id-1", deleted: false}
    end

    test "includes deleted flag for deleted messages" do
      msg = Message.new(:user, "Hello", "id-1")
      msg = Message.mark_deleted(msg)

      map = Message.to_map(msg)

      assert map.deleted == true
    end
  end
end
