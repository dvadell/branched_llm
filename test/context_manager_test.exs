defmodule BranchedLLM.ContextManagerTest do
  use ExUnit.Case, async: true

  alias BranchedLLM.ContextManager
  alias ReqLLM.Context

  describe "estimate_tokens/2" do
    test "returns 0 for empty context" do
      context = Context.new([])
      assert ContextManager.estimate_tokens(context) == 0
    end

    test "estimates tokens for a simple message" do
      # "Hello!!" = 7 bytes / 4 chars_per_token = 1 token (integer division)
      context = Context.new([Context.user("Hello!!")])
      assert ContextManager.estimate_tokens(context) == 1
    end

    test "estimates tokens across multiple messages" do
      # "You are helpful" = 15 chars, "Hello!!" = 7 chars => 22 chars / 4 = 5 tokens
      context =
        Context.new([
          Context.system("You are helpful"),
          Context.user("Hello!!")
        ])

      assert ContextManager.estimate_tokens(context) == 5
    end

    test "respects custom chars_per_token" do
      # "Hello!!" = 7 bytes / 2 chars_per_token = 3 tokens (integer division)
      context = Context.new([Context.user("Hello!!")])
      assert ContextManager.estimate_tokens(context, chars_per_token: 2) == 3
    end

    test "handles empty content gracefully" do
      context = Context.new([Context.user("")])
      assert ContextManager.estimate_tokens(context) == 0
    end
  end

  describe "trim/2" do
    test "returns context unchanged when max_tokens is :infinity" do
      context = Context.new([Context.system("System"), Context.user("Hello")])

      {result, was_trimmed} = ContextManager.trim(context, max_tokens: :infinity)
      assert result == context
      refute was_trimmed
    end

    test "returns context unchanged when within token limit" do
      context = Context.new([Context.system("Sys"), Context.user("Hi")])

      # Well within limit
      {result, was_trimmed} = ContextManager.trim(context, max_tokens: 100)
      assert result == context
      refute was_trimmed
    end

    test "trims oldest conversation messages when over limit" do
      context =
        Context.new([
          Context.system("System prompt"),
          Context.user("First question"),
          Context.assistant("First answer"),
          Context.user("Second question"),
          Context.assistant("Second answer")
        ])

      # A very low limit guarantees trimming occurs so we can verify the trim behavior
      {result, was_trimmed} = ContextManager.trim(context, max_tokens: 5)

      assert was_trimmed
      # System messages must be preserved
      system_msgs = Enum.filter(result.messages, fn msg -> msg.role == :system end)
      assert length(system_msgs) == 1
      # Most recent messages should be kept
      assert length(result.messages) < length(context.messages)
    end

    test "always preserves system messages" do
      context =
        Context.new([
          Context.system("Very important system prompt that must be kept"),
          Context.user("Question one"),
          Context.user("Question two")
        ])

      {result, _was_trimmed} = ContextManager.trim(context, max_tokens: 5)

      system_msgs = Enum.filter(result.messages, fn msg -> msg.role == :system end)
      assert length(system_msgs) == 1
      assert List.first(system_msgs).role == :system
    end

    test "keeps most recent messages when trimming" do
      context =
        Context.new([
          Context.system("Sys"),
          Context.user("Old question"),
          Context.assistant("Old answer"),
          Context.user("New question")
        ])

      {result, was_trimmed} = ContextManager.trim(context, max_tokens: 4)

      assert was_trimmed
      # The newest user message should be retained
      last_msg = List.last(result.messages)
      assert last_msg.role == :user
    end

    test "uses trim_callback when provided and context exceeds limit" do
      context =
        Context.new([
          Context.system("System"),
          Context.user("A very long question that should be summarized")
        ])

      # Custom callback that keeps only system + last user message
      callback = fn ctx ->
        system_msgs = Enum.filter(ctx.messages, fn msg -> msg.role == :system end)
        user_msgs = Enum.filter(ctx.messages, fn msg -> msg.role == :user end)
        last_user = List.last(user_msgs)
        %{ctx | messages: system_msgs ++ if(last_user, do: [last_user], else: [])}
      end

      {result, was_trimmed} =
        ContextManager.trim(context, max_tokens: 2, trim_callback: callback)

      assert was_trimmed
      assert length(result.messages) <= 2
    end

    test "falls back to pruning if trim_callback result still exceeds limit" do
      context =
        Context.new([
          Context.system("System"),
          Context.user("This is a very long question that exceeds the token limit by far")
        ])

      # Callback that does nothing (returns context as-is)
      no_op_callback = fn ctx -> ctx end

      {result, was_trimmed} =
        ContextManager.trim(context, max_tokens: 2, trim_callback: no_op_callback)

      assert was_trimmed
      # Should have been pruned after the callback failed to reduce size
      system_msgs = Enum.filter(result.messages, fn msg -> msg.role == :system end)
      assert length(system_msgs) == 1
    end

    test "handles trim_callback with {module, function} tuple" do
      context =
        Context.new([
          Context.system("System"),
          Context.user("Hello world question")
        ])

      {result, was_trimmed} =
        ContextManager.trim(context,
          max_tokens: 2,
          trim_callback: {__MODULE__, :noop_trim}
        )

      assert was_trimmed
      # The noop callback returns context as-is, so default pruning kicks in
      system_msgs = Enum.filter(result.messages, fn msg -> msg.role == :system end)
      assert length(system_msgs) == 1
    end

    test "rescues from failing trim_callback" do
      context =
        Context.new([
          Context.system("System"),
          Context.user("Hello")
        ])

      bad_callback = fn _ctx -> raise "oops" end

      {result, was_trimmed} =
        ContextManager.trim(context, max_tokens: 1, trim_callback: bad_callback)

      assert was_trimmed
      # Falls back to default pruning after callback raises
      system_msgs = Enum.filter(result.messages, fn msg -> msg.role == :system end)
      assert length(system_msgs) == 1
    end
  end

  describe "resolve_max_tokens/1" do
    test "returns explicit option value" do
      assert ContextManager.resolve_max_tokens(max_tokens: 50_000) == 50_000
    end

    test "returns :infinity when not configured" do
      original = Application.get_env(:branched_llm, :max_tokens)
      Application.delete_env(:branched_llm, :max_tokens)

      assert ContextManager.resolve_max_tokens([]) == :infinity

      if original, do: Application.put_env(:branched_llm, :max_tokens, original)
    end

    test "reads from app config when not in opts" do
      original = Application.get_env(:branched_llm, :max_tokens)
      Application.put_env(:branched_llm, :max_tokens, 99_000)

      assert ContextManager.resolve_max_tokens([]) == 99_000

      if original do
        Application.put_env(:branched_llm, :max_tokens, original)
      else
        Application.delete_env(:branched_llm, :max_tokens)
      end
    end
  end

  describe "resolve_trim_callback/1" do
    test "returns nil when no callback configured" do
      original = Application.get_env(:branched_llm, :trim_callback)
      Application.delete_env(:branched_llm, :trim_callback)

      assert ContextManager.resolve_trim_callback([]) == nil

      if original, do: Application.put_env(:branched_llm, :trim_callback, original)
    end

    test "returns function from explicit opts" do
      fun = fn ctx -> ctx end
      assert ContextManager.resolve_trim_callback(trim_callback: fun) == fun
    end

    test "resolves {module, function} tuple from explicit opts" do
      result = ContextManager.resolve_trim_callback(trim_callback: {__MODULE__, :noop_trim})
      assert is_function(result, 1)
    end

    test "resolves {module, function} tuple from app config" do
      original = Application.get_env(:branched_llm, :trim_callback)
      Application.put_env(:branched_llm, :trim_callback, {__MODULE__, :noop_trim})

      result = ContextManager.resolve_trim_callback([])
      assert is_function(result, 1)

      if original do
        Application.put_env(:branched_llm, :trim_callback, original)
      else
        Application.delete_env(:branched_llm, :trim_callback)
      end
    end
  end

  # Test helper for {module, function} callback resolution
  def noop_trim(ctx), do: ctx
end
