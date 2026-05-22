defmodule BranchedLLM.ContextManager do
  @moduledoc """
  Manages context window limits to prevent exceeding LLM token limits.

  As conversations grow, the accumulated messages can exceed the LLM's context
  window (e.g., 128k tokens for GPT-4), causing 400 errors from the API. This
  module provides a pre-send hook that trims the context before it is sent to
  the LLM.

  ## Strategy

  1. **Token estimation** — Approximates token count from message content using
     a conservative heuristic (~4 characters per token for English text).
  2. **Trimming** — When the estimated token count exceeds `max_tokens`, removes
     the oldest non-system messages until the context fits.
  3. **Custom callback** — Users can provide a `trim_callback` to implement
     custom strategies (e.g., summarization, sliding window with overlap).

  ## Configuration

  In `config/config.exs`:

      config :branched_llm,
        max_tokens: 128_000,
        trim_callback: {MyApp.ContextTrimmer, :trim}

  Or pass options directly to `trim/2`:

      ContextManager.trim(context, max_tokens: 50_000, trim_callback: &my_trimmer/1)

  ## Custom Trim Callback

  A trim callback receives a `ReqLLM.Context.t()` and must return a
  `ReqLLM.Context.t()`. This allows strategies like summarization:

      def summarize_context(context) do
        # Use an LLM to summarize older messages, then replace them
        # with a single summary message.
        context
      end

  If the callback returns a context that still exceeds `max_tokens`, the
  default pruning strategy is applied as a fallback.
  """

  alias ReqLLM.Context
  alias ReqLLM.Message

  @default_chars_per_token 4
  @default_max_tokens :infinity

  @type trim_opts :: [
          {:max_tokens, pos_integer() | :infinity}
          | {:trim_callback, (Context.t() -> Context.t()) | {module(), atom()}}
        ]

  @doc """
  Estimates the token count for a `ReqLLM.Context.t()`.

  Uses a character-based heuristic: sums the text length of all message content
  parts and divides by `chars_per_token` (default 4). This is a conservative
  approximation — real tokenizers vary by model and language, but this is
  sufficient for preventing context overflow.

  ## Options

    * `:chars_per_token` — Characters per estimated token (default 4).
      English text averages ~4 chars/token; CJK text is ~1.5–2 chars/token.
  """
  @spec estimate_tokens(Context.t(), keyword()) :: non_neg_integer()
  def estimate_tokens(%Context{messages: messages}, opts \\ []) do
    chars_per_token = Keyword.get(opts, :chars_per_token, @default_chars_per_token)

    messages
    |> Enum.reduce(0, fn msg, acc -> acc + message_char_length(msg) end)
    |> Kernel.div(chars_per_token)
    |> max(0)
  end

  @doc """
  Trims a context to fit within `max_tokens` if it exceeds the limit.

  Returns `{trimmed_context, was_trimmed}` where `was_trimmed` is `true` if any
  messages were removed.

  ## Flow

  1. If `max_tokens` is `:infinity`, return the context unchanged.
  2. If a `trim_callback` is provided, call it first and check if the result
     fits. If it does, return the callback's result.
  3. If the context still exceeds the limit (no callback, or callback result is
     still too large), apply the default pruning strategy: remove the oldest
     non-system messages until the estimated token count fits.

  ## Options

    * `:max_tokens` — Maximum token limit (default from app config, or `:infinity`).
    * `:trim_callback` — Optional `{module, function}` tuple or function that
      receives a `Context.t()` and returns a trimmed `Context.t()`.

  ## Examples

      # Using defaults from config
      {ctx, true} = ContextManager.trim(context)

      # With explicit options
      {ctx, _} = ContextManager.trim(context, max_tokens: 50_000)

      # With a custom summarization callback
      {ctx, _} = ContextManager.trim(context,
        max_tokens: 100_000,
        trim_callback: &MyTrimmer.summarize/1
      )
  """
  @spec trim(Context.t(), trim_opts()) :: {Context.t(), boolean()}
  def trim(%Context{} = context, opts \\ []) do
    max_tokens = resolve_max_tokens(opts)
    trim_callback = resolve_trim_callback(opts)

    cond do
      max_tokens == :infinity ->
        {context, false}

      estimate_tokens(context) <= max_tokens ->
        {context, false}

      trim_callback != nil ->
        trimmed = apply_trim_callback(trim_callback, context)

        if estimate_tokens(trimmed) <= max_tokens do
          {trimmed, true}
        else
          {prune_to_fit(trimmed, max_tokens), true}
        end

      true ->
        {prune_to_fit(context, max_tokens), true}
    end
  end

  @doc """
  Returns the effective max_tokens setting.

  Checks (in order):
  1. Explicit `max_tokens` in `opts`
  2. Application config `:branched_llm, :max_tokens`
  3. Default `:infinity`
  """
  @spec resolve_max_tokens(keyword()) :: pos_integer() | :infinity
  def resolve_max_tokens(opts) do
    case Keyword.get(opts, :max_tokens) do
      nil -> Application.get_env(:branched_llm, :max_tokens, @default_max_tokens)
      val -> val
    end
  end

  @doc """
  Returns the effective trim_callback setting.

  Checks (in order):
  1. Explicit `:trim_callback` in `opts`
  2. Application config `:branched_llm, :trim_callback`
  3. `nil` (no callback)
  """
  @spec resolve_trim_callback(keyword()) :: (Context.t() -> Context.t()) | nil
  def resolve_trim_callback(opts) do
    case Keyword.get(opts, :trim_callback) do
      nil ->
        case Application.get_env(:branched_llm, :trim_callback) do
          nil -> nil
          {mod, fun} -> &apply(mod, fun, [&1])
          fun when is_function(fun, 1) -> fun
        end

      {mod, fun} ->
        &apply(mod, fun, [&1])

      fun when is_function(fun, 1) ->
        fun
    end
  end

  ## Private Helpers

  # Sum character lengths of all text ContentParts in a message.
  @spec message_char_length(Message.t()) :: non_neg_integer()
  defp message_char_length(%Message{content: content_parts}) when is_list(content_parts) do
    Enum.reduce(content_parts, 0, fn
      %{type: :text, text: text}, acc when is_binary(text) -> acc + byte_size(text)
      _, acc -> acc
    end)
  end

  defp message_char_length(%Message{content: content}) when is_binary(content) do
    byte_size(content)
  end

  defp message_char_length(_), do: 0

  # Apply the user-provided trim callback, rescuing on errors.
  @spec apply_trim_callback((Context.t() -> Context.t()), Context.t()) :: Context.t()
  defp apply_trim_callback(callback, context) do
    callback.(context)
  rescue
    e ->
      require Logger

      Logger.warning(
        "ContextManager trim_callback failed: #{inspect(e)}. Falling back to pruning."
      )

      context
  end

  # Default pruning strategy: remove oldest non-system messages until
  # the estimated token count is within `max_tokens`.
  #
  # System messages are always preserved. The most recent messages
  # (typically the user's question and recent context) are kept.
  @spec prune_to_fit(Context.t(), pos_integer()) :: Context.t()
  defp prune_to_fit(%Context{messages: messages} = context, max_tokens) do
    {system_messages, conversation_messages} =
      Enum.split_with(messages, fn
        %Message{role: :system} -> true
        _ -> false
      end)

    pruned_conversation =
      drop_oldest_until_fits(conversation_messages, max_tokens, system_messages)

    %{context | messages: system_messages ++ pruned_conversation}
  end

  # Iteratively drop the oldest conversation messages until the total
  # estimated tokens (system + remaining conversation) fit within max_tokens.
  @spec drop_oldest_until_fits([Message.t()], pos_integer(), [Message.t()]) :: [Message.t()]
  defp drop_oldest_until_fits(conversation_messages, max_tokens, system_messages) do
    system_token_estimate =
      system_messages
      |> Enum.reduce(0, fn msg, acc -> acc + message_char_length(msg) end)
      |> Kernel.div(@default_chars_per_token)

    available_tokens = max_tokens - system_token_estimate

    drop_until_fits(conversation_messages, available_tokens, [])
  end

  @spec drop_until_fits([Message.t()], non_neg_integer(), [Message.t()]) :: [Message.t()]
  defp drop_until_fits([], _available_tokens, acc), do: Enum.reverse(acc)

  defp drop_until_fits([head | tail], available_tokens, acc) do
    head_tokens =
      max(message_char_length(head) |> Kernel.div(@default_chars_per_token), 1)

    current_total =
      acc
      |> Enum.reduce(0, fn msg, sum ->
        sum + max(message_char_length(msg) |> Kernel.div(@default_chars_per_token), 1)
      end)

    if current_total + head_tokens <= available_tokens do
      drop_until_fits(tail, available_tokens, [head | acc])
    else
      # Even if we can't fit this message, keep trying from the tail
      # (drop this message and continue checking if the rest fits)
      drop_until_fits(tail, available_tokens, acc)
    end
  end
end
