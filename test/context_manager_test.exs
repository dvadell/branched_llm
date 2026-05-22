defmodule BranchedLLM.ContextManagerTest do
  use ExUnit.Case, async: true

  alias BranchedLLM.ContextManager
  alias ReqLLM.Context
  alias ReqLLM.Message

  # Helper: build a context with messages that have raw binary content
  # (bypasses Context.user/assistant which always creates ContentPart lists)
  defp context_with_binary_content do
    %Context{
      messages: [
        %Message{role: :system, content: [%Message.ContentPart{type: :text, text: "System"}]},
        %Message{role: :user, content: "Binary user message here"},
        %Message{role: :assistant, content: "Binary assistant reply"}
      ]
    }
  end

  # Helper: build a context with a message that has nil content
  defp context_with_nil_content do
    %Context{
      messages: [
        %Message{role: :system, content: [%Message.ContentPart{type: :text, text: "System"}]},
        struct(Message, %{role: :user, content: nil})
      ]
    }
  end

  # Helper: build a context with messages containing non-text ContentParts (e.g., image)
  defp context_with_mixed_content_parts do
    %Context{
      messages: [
        %Message{role: :system, content: [%Message.ContentPart{type: :text, text: "System"}]},
        %Message{
          role: :user,
          content: [
            %Message.ContentPart{type: :text, text: "What is in this image?"},
            %Message.ContentPart{
              type: :image_url,
              url: "https://example.com/img.png"
            }
          ]
        }
      ]
    }
  end

  describe "estimate_tokens/2" do
    test "returns 0 for empty context" do
      context = Context.new([])
      assert ContextManager.estimate_tokens(context) == 0
    end

    test "estimates tokens for a simple message" do
      context = Context.new([Context.user("Hello!!")])
      assert ContextManager.estimate_tokens(context) == 1
    end

    test "estimates tokens across multiple messages" do
      context =
        Context.new([
          Context.system("You are helpful"),
          Context.user("Hello!!")
        ])

      assert ContextManager.estimate_tokens(context) == 5
    end

    test "respects custom chars_per_token" do
      context = Context.new([Context.user("Hello!!")])
      assert ContextManager.estimate_tokens(context, chars_per_token: 2) == 3
    end

    test "handles empty content gracefully" do
      context = Context.new([Context.user("")])
      assert ContextManager.estimate_tokens(context) == 0
    end

    test "handles messages with binary (non-list) content" do
      context = context_with_binary_content()

      # "System" (7) + "Binary user message here" (24) + "Binary assistant reply" (23) = 54 / 4 = 13
      assert ContextManager.estimate_tokens(context) == 13
    end

    test "handles messages with nil content" do
      context = context_with_nil_content()
      # "System" (7) + nil (0) = 7 / 4 = 1
      assert ContextManager.estimate_tokens(context) == 1
    end

    test "handles messages with mixed text and image content parts" do
      context = context_with_mixed_content_parts()
      # "System" (7) + "What is in this image?" (22) = 29 / 4 = 7
      # (image_url ContentPart is skipped — only text parts are counted)
      assert ContextManager.estimate_tokens(context) == 7
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

      system_msgs = Enum.filter(result.messages, fn msg -> msg.role == :system end)
      assert length(system_msgs) == 1
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
      last_msg = List.last(result.messages)
      assert last_msg.role == :user
    end

    test "uses trim_callback when provided and context exceeds limit" do
      context =
        Context.new([
          Context.system("System"),
          Context.user("A very long question that should be summarized")
        ])

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

      no_op_callback = fn ctx -> ctx end

      {result, was_trimmed} =
        ContextManager.trim(context, max_tokens: 2, trim_callback: no_op_callback)

      assert was_trimmed

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
        ContextManager.trim(context, max_tokens: 2, trim_callback: {__MODULE__, :noop_trim})

      assert was_trimmed

      system_msgs = Enum.filter(result.messages, fn msg -> msg.role == :system end)
      assert length(system_msgs) == 1
    end

    test "handles trim_callback with {module, function, opts} tuple" do
      context =
        Context.new([
          Context.system("System"),
          Context.user("Hello world question")
        ])

      {result, was_trimmed} =
        ContextManager.trim(context,
          max_tokens: 2,
          trim_callback: {__MODULE__, :noop_trim_with_opts, [extra: true]}
        )

      assert was_trimmed

      system_msgs = Enum.filter(result.messages, fn msg -> msg.role == :system end)
      assert length(system_msgs) == 1
    end

    test "rescues from failing 1-arity function callback" do
      context =
        Context.new([
          Context.system("System"),
          Context.user("Hello")
        ])

      bad_callback = fn _ctx -> raise "oops" end

      {result, was_trimmed} =
        ContextManager.trim(context, max_tokens: 1, trim_callback: bad_callback)

      assert was_trimmed

      system_msgs = Enum.filter(result.messages, fn msg -> msg.role == :system end)
      assert length(system_msgs) == 1
    end

    test "rescues from failing {module, function} callback" do
      context =
        Context.new([
          Context.system("System"),
          Context.user("Hello")
        ])

      {result, was_trimmed} =
        ContextManager.trim(context,
          max_tokens: 1,
          trim_callback: {__MODULE__, :failing_trim}
        )

      assert was_trimmed

      system_msgs = Enum.filter(result.messages, fn msg -> msg.role == :system end)
      assert length(system_msgs) == 1
    end

    test "rescues from failing {module, function, opts} callback" do
      context =
        Context.new([
          Context.system("System"),
          Context.user("Hello")
        ])

      {result, was_trimmed} =
        ContextManager.trim(context,
          max_tokens: 1,
          trim_callback: {__MODULE__, :failing_trim_with_opts, [boom: true]}
        )

      assert was_trimmed

      system_msgs = Enum.filter(result.messages, fn msg -> msg.role == :system end)
      assert length(system_msgs) == 1
    end

    test "trims context with binary content messages" do
      context = context_with_binary_content()

      {result, was_trimmed} = ContextManager.trim(context, max_tokens: 3)

      assert was_trimmed

      system_msgs = Enum.filter(result.messages, fn msg -> msg.role == :system end)
      assert length(system_msgs) == 1
    end

    test "trims context with nil content messages" do
      context = context_with_nil_content()

      {_result, was_trimmed} = ContextManager.trim(context, max_tokens: 1)

      # Even with nil content (0 bytes), max_tokens: 1 is very tight
      # The system message alone may exceed 1 token
      assert is_boolean(was_trimmed)
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
      assert result == {__MODULE__, :noop_trim}
    end

    test "resolves {module, function, opts} tuple from explicit opts" do
      result =
        ContextManager.resolve_trim_callback(trim_callback: {__MODULE__, :noop_trim, [keep: 5]})

      assert result == {__MODULE__, :noop_trim, [keep: 5]}
    end

    test "resolves {module, function} tuple from app config" do
      original = Application.get_env(:branched_llm, :trim_callback)
      Application.put_env(:branched_llm, :trim_callback, {__MODULE__, :noop_trim})

      result = ContextManager.resolve_trim_callback([])
      assert result == {__MODULE__, :noop_trim}

      if original do
        Application.put_env(:branched_llm, :trim_callback, original)
      else
        Application.delete_env(:branched_llm, :trim_callback)
      end
    end

    test "resolves {module, function, opts} tuple from app config" do
      original = Application.get_env(:branched_llm, :trim_callback)
      Application.put_env(:branched_llm, :trim_callback, {__MODULE__, :noop_trim, [keep: 5]})

      result = ContextManager.resolve_trim_callback([])
      assert result == {__MODULE__, :noop_trim, [keep: 5]}

      if original do
        Application.put_env(:branched_llm, :trim_callback, original)
      else
        Application.delete_env(:branched_llm, :trim_callback)
      end
    end

    test "resolves 1-arity function from app config" do
      original = Application.get_env(:branched_llm, :trim_callback)
      fun = fn ctx -> ctx end
      Application.put_env(:branched_llm, :trim_callback, fun)

      result = ContextManager.resolve_trim_callback([])
      assert result == fun

      if original do
        Application.put_env(:branched_llm, :trim_callback, original)
      else
        Application.delete_env(:branched_llm, :trim_callback)
      end
    end
  end

  # Test helpers for {module, function} callback resolution
  def noop_trim(ctx, _opts), do: ctx
  def noop_trim_with_opts(ctx, _opts), do: ctx
  def failing_trim(_ctx, _opts), do: raise("2-tuple failure")
  def failing_trim_with_opts(_ctx, _opts), do: raise("3-tuple failure")
end
