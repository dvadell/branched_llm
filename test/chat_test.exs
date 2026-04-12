defmodule BranchedLLM.ChatTest do
  use ExUnit.Case, async: true
  alias BranchedLLM.Chat
  alias ReqLLM.Context

  describe "new_context/1" do
    test "creates a context with system message" do
      context = Chat.new_context("You are helpful")

      assert length(context.messages) == 1
      assert List.first(context.messages).role == :system
    end
  end

  describe "get_history/1" do
    test "returns the messages from context" do
      context = Chat.new_context("System")

      history = Chat.get_history(context)
      assert length(history) == 1
    end
  end

  describe "reset_context/1" do
    test "keeps only system messages" do
      context =
        Context.new([
          Context.system("System"),
          Context.user("Hello"),
          Context.assistant("Hi")
        ])

      reset = Chat.reset_context(context)

      assert length(reset.messages) == 1
      assert List.first(reset.messages).role == :system
    end
  end

  describe "default_model/0" do
    test "returns the configured model" do
      model = Chat.default_model()
      assert is_binary(model)
    end
  end
end
