# BranchedLLM [![Hex.pm](https://img.shields.io/hexpm/v/branched_llm.svg)](https://hex.pm/packages/branched_llm) [![HexDocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/branched_llm) [![License](https://img.shields.io/hexpm/l/branched_llm.svg)](https://hex.pm/packages/branched_llm)

A wrapper around [ReqLLM](https://hex.pm/packages/req_llm) that adds **branching conversations**, **tool execution**, and **async orchestration** on top of it.

BranchedLLM provides the conversation management layer — branching, message queuing, streaming orchestration — while relying on ReqLLM for all LLM API communication. If you need to talk to a different LLM provider than what ReqLLM supports, this library is not the right fit.

---

## Features

- **Branching conversations** — Fork any conversation at any message to explore alternative responses. Each branch maintains its own context and message history independently.
- **Tool calling** — Built-in support for LLM tool use (via ReqLLM) with automatic detection, execution, and result injection. Includes retry limits and result caching.
- **Streaming responses** — Real-time token streaming via a clean message protocol between the orchestrator and your UI layer.
- **Context window management** — Automatic context trimming to prevent token limit errors. Configurable max tokens and custom trim callbacks (e.g., summarization).
- **Domain-agnostic** — No knowledge of education, chat apps, or web frameworks. Pure data structures and well-defined message protocols.
- **Observable** — Optional OpenTelemetry spans and Telemetry events for monitoring.

---

## Installation

Add `branched_llm` to your dependencies:

```elixir
def deps do
  [
    {:branched_llm, "~> 0.1.1"}
  ]
end
```

### Dependencies

BranchedLLM requires:

| Dependency | Purpose | Required |
|---|---|---|
| [`req_llm`](https://hex.pm/packages/req_llm) | LLM API communication | Yes |
| [`ecto`](https://hex.pm/packages/ecto) | Tool result caching | Optional |
| [`jason`](https://hex.pm/packages/jason) | JSON encoding | Yes |
| [`retry`](https://hex.pm/packages/retry) | Automatic retry on failures | Yes |
| [`telemetry`](https://hex.pm/packages/telemetry) | Metrics events | Yes |
| `opentelemetry_api` | Distributed tracing | Optional |

### Configuration

Configure the LLM connection in `config/config.exs`:

```elixir
config :branched_llm,
  ai_model: "openai:gpt-4o",
  base_url: "http://localhost:11434"

# ReqLLM configuration (OpenAI-compatible)
config :req_llm,
  openai: [
    api_key: System.get_env("OPENAI_API_KEY")
  ]
```

For tool result caching, the library defaults to `BranchedLLM.ToolCache.InMemory` (no-op). To use Ecto:

```elixir
# mix.exs
{:ecto, "~> 3.13"}

# config/config.exs
config :branched_llm, :tool_cache, BranchedLLM.ToolCache.Ecto
config :branched_llm, BranchedLLM.ToolCache, repo: MyApp.Repo
```

### Context Window Configuration

By default, conversations grow without limit, which can exceed the LLM's context window. Configure a max token limit to enable automatic trimming:

```elixir
config :branched_llm, max_tokens: 128_000
```

When the context exceeds this limit, the configured strategy is invoked before the LLM call. System messages are always preserved.

#### Built-in Strategies

| Strategy | Description | Key option |
|---|---|---|
| `Strategy.Prune` | Drop oldest non-system messages until context fits (default) | — |
| `Strategy.SlidingWindow` | Keep only the last N messages | `keep: N` |
| `Strategy.Percentage` | Keep the last X% of conversation tokens | `retain: 0.7` |
| `Strategy.Summarize` | Condense older messages into a summary | `recent_count: 4` |

Configure a strategy using a `{module, function, opts}` tuple:

```elixir
# SlidingWindow: keep last 20 messages
config :branched_llm,
  max_tokens: 128_000,
  trim_callback: {BranchedLLM.ContextManager.Strategy.SlidingWindow, :trim, [keep: 20]}

# Percentage: keep last 70% of tokens
config :branched_llm,
  max_tokens: 128_000,
  trim_callback: {BranchedLLM.ContextManager.Strategy.Percentage, :trim, [retain: 0.7]}
```

Or pass per-call:

```elixir
Chat.send_message_stream("Hello!", context,
  max_tokens: 50_000,
  trim_callback: {BranchedLLM.ContextManager.Strategy.SlidingWindow, :trim, [keep: 10]}
)
```

If the strategy result still exceeds `max_tokens`, `Strategy.Prune` is applied as a fallback.

#### Custom Strategies

Implement the `BranchedLLM.ContextManager.Strategy` behaviour:

```elixir
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
```

Then configure it:

```elixir
config :branched_llm,
  max_tokens: 128_000,
  trim_callback: {MyApp.Strategy.KeepRecent, :trim, [keep: 20]}
```

---

## Quick Start

### 1. Create a conversation context

```elixir
alias BranchedLLM.Chat

context = Chat.new_context("You are a helpful assistant.")
```

### 2. Send a message

```elixir
{:ok, response, new_context} = Chat.send_message("What is Elixir?", context)
IO.puts(response)
```

### 3. Streaming with tools

```elixir
alias BranchedLLM.LLM.StreamResult.{ContentResult, ToolCallResult}

calculator_tool = ReqLLM.Tool.new!(
  name: "calculator",
  description: "Evaluates a mathematical expression",
  parameter_schema: %{
    type: "object",
    properties: %{expression: %{type: "string"}}
  },
  callback: fn %{"expression" => expr} ->
    # SECURITY WARNING: Using Code.eval_string on LLM output is dangerous.
    # In a production app, use a safe math library or a restricted parser.
    {result, _} = Code.eval_string(expr)
    {:ok, to_string(result)}
  end
)

{:ok, result} = Chat.send_message_stream("What is 123 * 456?", context, tools: [calculator_tool])

case result do
  %ContentResult{stream: stream} ->
    # The LLM is streaming text — iterate tokens
    stream
    |> ReqLLM.StreamResponse.tokens()
    |> Enum.each(fn chunk -> IO.write(chunk) end)

  %ToolCallResult{tool_calls: calls} ->
    # The LLM is calling tools — handled automatically by the orchestrator
    IO.puts("Tool calls: #{inspect(calls)}")
end
```

### 4. Branching conversations

```elixir
alias BranchedLLM.{BranchedChat, Message}

# The system prompt lives in the ReqLLM.Context, no need to duplicate it in messages
branched_chat = BranchedChat.new(Chat, [], context)

# Add a message
branched_chat = BranchedChat.add_user_message(branched_chat, "What is 2+2?")
last_msg = List.last(BranchedChat.get_current_messages(branched_chat))

# Branch off from this message to explore alternatives
branched_chat = BranchedChat.branch_off(branched_chat, last_msg.id)

# Switch back to the main branch
branched_chat = BranchedChat.switch_branch(branched_chat, "main")
```

---

## Architecture

### Core Modules

| Module | Responsibility |
|---|---|
| `BranchedLLM.Message` | Immutable message struct with role, content, id, and metadata |
| `BranchedLLM.BranchedChat` | Tree-like conversation state with branching support |
| `BranchedLLM.Chat` | ReqLLM-based chat implementation |
| `BranchedLLM.ChatOrchestrator` | Async request orchestration with retry and tool call loops |
| `BranchedLLM.ContextManager` | Context window limit enforcement and trimming |
| `BranchedLLM.ContextManager.Strategy` | Behaviour for pluggable trim strategies |
| `BranchedLLM.ContextManager.Strategy.Prune` | Drop oldest messages (default fallback) |
| `BranchedLLM.ContextManager.Strategy.SlidingWindow` | Keep last N messages |
| `BranchedLLM.ContextManager.Strategy.Percentage` | Keep last X% of tokens |
| `BranchedLLM.ContextManager.Strategy.Summarize` | Summarize older messages |
| `BranchedLLM.ToolHandler` | Orchestrates tool execution and context injection |
| `BranchedLLM.ToolCache` | Ecto-based tool result caching |
| `BranchedLLM.LLM.StreamParser` | Stream intent detection and tool call extraction |
| `BranchedLLM.LLM.StreamResult` | Tagged-union result types (`ContentResult`, `ToolCallResult`, `EmptyResult`) |
| `BranchedLLM.LLMErrorFormatter` | User-friendly error message formatting |

### Stream Result Types

`Chat.send_message_stream/3` returns a tagged union that clearly distinguishes the LLM's intent:

| Struct | Meaning | Key fields |
|---|---|---|
| `%ContentResult{}` | LLM is streaming text | `stream`, `context_builder` |
| `%ToolCallResult{}` | LLM is invoking tools | `tool_calls`, `context`, `context_builder` |
| `%EmptyResult{}` | LLM returned nothing | `context_builder` |

This eliminates the need for callers to inspect `tool_calls` lists or handle dummy streams — the intent is explicit in the type.

### Context Window Management

The `ContextManager` prevents context overflow by:

1. **Estimating tokens** from message content (~4 characters per token by default)
2. **Trimming before LLM calls** in `Chat.send_message_stream/3` and `BranchedChat.rebuild_context_from_messages/2`
3. **Preserving system messages** while removing the oldest conversation messages
4. **Supporting pluggable strategies** via the `Strategy` behaviour — four built-in strategies are provided

When trimming occurs, only the context sent to the LLM is trimmed. The full message history in `BranchedChat` is preserved — the `context_builder` closure captures the untrimmed context so that `finish_ai_response` stores the complete conversation.

Trimming only runs when the estimated token count **exceeds** `max_tokens`. By default, `max_tokens` is `:infinity` — no trimming occurs unless you configure it.

### Message Protocol

The `ChatOrchestrator` communicates with the caller via a callback function (`on_event`):

```elixir
{:llm_chunk, branch_id, chunk}              # Streaming text chunk
{:llm_end, branch_id, context_builder}      # Stream complete
{:llm_status, branch_id, status}            # Status update ("Thinking...", "Using calculator...")
{:llm_error, branch_id, error_message}      # Error occurred
{:update_tool_usage_counts, counts}          # Updated tool usage tracking
```

This allows you to easily pipe events to processes (`send/2`), write directly to STDOUT, or integrate with any other side-effect.

---

## Guides

- **[Getting Started](guides/getting_started.md)** — Step-by-step tutorial for first-time users
- **[Interactive IEx Tutorial](guides/tutorial_iex.md)** — Hands-on walkthrough in the Elixir shell
- **[Comparison with ReqLLM](guides/comparison_req_llm.md)** — Why use BranchedLLM over raw ReqLLM?

---

## 📄 License

MIT License. See [LICENSE](https://github.com/dvadell/branched_llm/blob/main/LICENSE) for details.
