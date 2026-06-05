defmodule BranchedLLM.ContextManager do
  @moduledoc """
  Manages context window limits to prevent exceeding LLM token limits.

  As conversations grow, the accumulated messages can exceed the LLM's context
  window (e.g., 128k tokens for GPT-4), causing 400 errors from the API. This
  module provides a pre-send hook that trims the context before it is sent to
  the LLM.

  ## When does trimming happen?

  Trimming only runs when the estimated token count **exceeds** `max_tokens`.
  If `max_tokens` is `:infinity` (the default) or the context is within limits,
  the context passes through untouched — no callback runs, no messages are dropped.

  ## Strategy

  1. **Token estimation** — Approximates token count from message content using
     a conservative heuristic (~4 characters per token for English text).
  2. **Trimming** — When the estimated token count exceeds `max_tokens`, the
     configured `trim_callback` is invoked. If no callback is set, the default
     `Strategy.Prune` is used (drops oldest non-system messages).
  3. **Fallback** — If the callback result still exceeds `max_tokens`, the
     `Strategy.Prune` strategy is applied to the callback's output.

  ## Configuration

  In `config/config.exs`:

      # Enable trimming with the default Prune strategy
      config :branched_llm, max_tokens: 128_000

      # Enable trimming with a built-in strategy
      config :branched_llm,
        max_tokens: 128_000,
        trim_callback: {BranchedLLM.ContextManager.Strategy.SlidingWindow, :trim, [keep: 20]}

      # Or with a custom function
      config :branched_llm,
        max_tokens: 128_000,
        trim_callback: &MyApp.ContextTrimmer.trim/1

  Or pass options directly to `trim/2`:

      ContextManager.trim(context, max_tokens: 50_000)
      ContextManager.trim(context, max_tokens: 128_000, trim_callback: {Strategy.SlidingWindow, :trim, [keep: 10]})

  ## Built-in Strategies

  | Strategy | Description | Key option |
  |---|---|---|
  | `Strategy.Prune` | Drop oldest non-system messages until context fits | — |
  | `Strategy.SlidingWindow` | Keep only the last N messages | `keep: N` |
  | `Strategy.Percentage` | Keep the last X% of conversation tokens | `retain: 0.7` |
  | `Strategy.Summarize` | Condense older messages into a summary | `recent_count: 4` |

  See `BranchedLLM.ContextManager.Strategy` for details on implementing custom strategies.

  ## Default Behavior

  By default, `max_tokens` is `:infinity` and `trim_callback` is `nil`.
  This means **no trimming occurs** — the context passes through unchanged.
  You must explicitly set `max_tokens` to enable trimming.
  """

  alias BranchedLLM.ContextManager.Strategy.Prune
  alias ReqLLM.Context
  alias ReqLLM.Message

  @default_chars_per_token 4
  @default_max_tokens :infinity

  @type trim_callback ::
          {module(), atom(), keyword()} | {module(), atom()} | (Context.t() -> Context.t())

  @type trim_opts :: [
          {:max_tokens, pos_integer() | :infinity}
          | {:trim_callback, trim_callback()}
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
  2. If the estimated token count is within `max_tokens`, return unchanged.
  3. If a `trim_callback` is provided, call it. If the result fits, return it.
  4. If the context still exceeds the limit, apply `Strategy.Prune` as fallback.

  ## Options

    * `:max_tokens` — Maximum token limit (default from app config, or `:infinity`).
    * `:trim_callback` — A strategy callback in one of three forms:
      - `{module, function}` — calls `module.function(context, [])`
      - `{module, function, opts}` — calls `module.function(context, opts)`
      - A 1-arity function — calls `function.(context)`

  ## Examples

      # Default: no trimming (max_tokens is :infinity)
      {ctx, false} = ContextManager.trim(context)

      # With a token limit (uses Strategy.Prune by default)
      {ctx, true} = ContextManager.trim(context, max_tokens: 50_000)

      # With a built-in strategy
      {ctx, _} = ContextManager.trim(context,
        max_tokens: 128_000,
        trim_callback: {BranchedLLM.ContextManager.Strategy.SlidingWindow, :trim, [keep: 20]}
      )

      # With a custom function
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
          {Prune.trim(trimmed, max_tokens: max_tokens), true}
        end

      true ->
        {Prune.trim(context, max_tokens: max_tokens), true}
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
  3. `nil` (no callback — `Strategy.Prune` is used as default)

  Supports three callback forms:
  - `{module, function}` — calls `module.function(context, [])`
  - `{module, function, opts}` — calls `module.function(context, opts)`
  - A 1-arity function — calls `function.(context)`
  """
  @spec resolve_trim_callback(keyword()) :: trim_callback() | nil
  def resolve_trim_callback(opts) do
    case Keyword.get(opts, :trim_callback) do
      nil -> resolve_app_config_callback()
      callback -> normalize_callback(callback)
    end
  end

  defp normalize_callback({mod, fun, opts})
       when is_atom(mod) and is_atom(fun) and is_list(opts) do
    {mod, fun, opts}
  end

  defp normalize_callback({mod, fun}) when is_atom(mod) and is_atom(fun) do
    {mod, fun}
  end

  defp normalize_callback(fun) when is_function(fun, 1) do
    fun
  end

  defp resolve_app_config_callback do
    case Application.get_env(:branched_llm, :trim_callback) do
      nil -> nil
      callback -> normalize_callback(callback)
    end
  end

  ## Private Helpers

  # Sum character lengths of all text ContentParts in a message.
  @spec message_char_length(Message.t()) :: non_neg_integer()
  defp message_char_length(%Message{content: content_parts}) when is_list(content_parts) do
    Enum.reduce(content_parts, 0, fn
      %{type: :text, text: text}, acc when is_binary(text) -> acc + byte_size(text)
    end)
  end

  # Apply the user-provided trim callback, rescuing on errors.
  @spec apply_trim_callback(term(), Context.t()) :: Context.t()
  defp apply_trim_callback({mod, fun, strategy_opts}, context) do
    apply(mod, fun, [context, strategy_opts])
  rescue
    e ->
      require Logger

      Logger.warning(
        "ContextManager trim_callback {#{mod}, #{fun}} failed: #{inspect(e)}. Falling back to pruning."
      )

      context
  end

  defp apply_trim_callback({mod, fun}, context) do
    apply(mod, fun, [context, []])
  rescue
    e ->
      require Logger

      Logger.warning(
        "ContextManager trim_callback {#{mod}, #{fun}} failed: #{inspect(e)}. Falling back to pruning."
      )

      context
  end

  defp apply_trim_callback(callback, context) when is_function(callback, 1) do
    callback.(context)
  rescue
    e ->
      require Logger

      Logger.warning(
        "ContextManager trim_callback failed: #{inspect(e)}. Falling back to pruning."
      )

      context
  end
end
