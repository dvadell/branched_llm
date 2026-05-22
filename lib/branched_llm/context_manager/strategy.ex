defmodule BranchedLLM.ContextManager.Strategy do
  @moduledoc """
  Behaviour for context trimming strategies.

  Each strategy implements a single `trim/2` callback that receives a
  `ReqLLM.Context.t()` and keyword options, and returns a trimmed
  `ReqLLM.Context.t()`.

  Strategies are designed to be used as `trim_callback` values in
  `BranchedLLM.ContextManager.trim/2`:

      # Via {module, function} tuple
      config :branched_llm,
        max_tokens: 128_000,
        trim_callback: {BranchedLLM.ContextManager.Strategy.SlidingWindow, :trim}

      # Or per-call
      ContextManager.trim(context,
        max_tokens: 128_000,
        trim_callback: {BranchedLLM.ContextManager.Strategy.SlidingWindow, :trim, [keep: 20]}
      )

  ## Built-in Strategies

  | Strategy | Description | Key option |
  |---|---|---|
  | `Strategy.Prune` | Drop oldest non-system messages until context fits (default fallback) | — |
  | `Strategy.SlidingWindow` | Keep only the last N messages | `keep: N` |
  | `Strategy.Percentage` | Keep the last X% of conversation tokens | `retain: 0.7` |
  | `Strategy.Summarize` | Summarize older messages into a single summary (stub) | `summarizer: fn/1` |

  ## Implementing a Custom Strategy

  A strategy is any module that exports a `trim/2` function with the signature:

      @callback trim(context :: ReqLLM.Context.t(), opts :: keyword()) :: ReqLLM.Context.t()

  Minimal example:

      defmodule MyApp.Strategy.KeepRecent do
        @behaviour BranchedLLM.ContextManager.Strategy

        @impl true
        def trim(context, opts) do
          keep = Keyword.get(opts, :keep, 10)
          system = Enum.filter(context.messages, fn msg -> msg.role == :system end)
          conversation = Enum.reject(context.messages, fn msg -> msg.role == :system end)
          recent = Enum.take(conversation, -keep)
          %{context | messages: system ++ recent}
        end
      end

  Then configure it:

      config :branched_llm,
        max_tokens: 128_000,
        trim_callback: {MyApp.Strategy.KeepRecent, :trim, [keep: 20]}

  The strategy's `opts` come from the third element of the tuple (`[keep: 20]`),
  or an empty list if omitted.
  """

  alias ReqLLM.Context

  @callback trim(context :: Context.t(), opts :: keyword()) :: Context.t()
end
