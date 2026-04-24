# BranchedLLM

[![Hex.pm](https://img.shields.io/hexpm/v/branched_llm.svg)](https://hex.pm/packages/branched_llm)
[![HexDocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/branched_llm)
[![License](https://img.shields.io/hexpm/l/branched_llm.svg)](https://hex.pm/packages/branched_llm)

A wrapper around [ReqLLM](https://hex.pm/packages/req_llm) that adds **branching conversations**, **tool execution**, and **async orchestration** on top of it.

BranchedLLM provides the conversation management layer — branching, message queuing, streaming orchestration — while relying on ReqLLM for all LLM API communication. If you need to talk to a different LLM provider than what ReqLLM supports, this library is not the right fit.

---

## ✨ Features

- **🌳 Branching conversations** — Fork any conversation at any message to explore alternative responses. Each branch maintains its own context and message history independently.
- **🔧 Tool calling** — Built-in support for LLM tool use (via ReqLLM) with automatic detection, execution, and result injection. Includes retry limits and result caching.
- **📡 Streaming responses** — Real-time token streaming via a clean message protocol between the orchestrator and your UI layer.
- **🧪 Domain-agnostic** — No knowledge of education, chat apps, or web frameworks. Pure data structures and well-defined message protocols.
- **📊 Observable** — Optional OpenTelemetry spans and Telemetry events for monitoring.

---

## 📦 Installation

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
| [`ecto`](https://hex.pm/packages/ecto) | Tool result caching | Yes (runtime) |
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

For tool result caching, configure the Ecto repo:

```elixir
config :branched_llm, BranchedLLM.ToolCache,
  repo: MyApp.Repo
```

---

## 🚀 Quick Start

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
calculator_tool = ReqLLM.Tool.new(
  name: "calculator",
  description: "Evaluates a mathematical expression",
  parameters: %{
    type: "object",
    properties: %{expression: %{type: "string"}}
  },
  execute: fn %{"expression" => expr} ->
    {result, _} = Code.eval_string(expr)
    {:ok, to_string(result)}
  end
)

{:ok, stream_response, context_builder, tool_calls} =
  Chat.send_message_stream("What is 123 * 456?", context, tools: [calculator_tool])

# Consume the stream
stream_response
|> ReqLLM.StreamResponse.tokens()
|> Enum.each(fn chunk -> IO.write(chunk.text) end)
```

### 4. Branching conversations

```elixir
alias BranchedLLM.{BranchedChat, Message}

# Start with an initial conversation
messages = [Message.new(:system, "You are helpful.")]
branched_chat = BranchedChat.new(Chat, messages, context)

# Add a message
branched_chat = BranchedChat.add_user_message(branched_chat, "What is 2+2?")
last_msg = List.last(BranchedChat.get_current_messages(branched_chat))

# Branch off from this message to explore alternatives
branched_chat = BranchedChat.branch_off(branched_chat, last_msg.id)

# Switch back to the main branch
branched_chat = BranchedChat.switch_branch(branched_chat, "main")
```

---

## 📖 Architecture

### Core Modules

| Module | Responsibility |
|---|---|
| `BranchedLLM.Message` | Immutable message struct with role, content, id, and metadata |
| `BranchedLLM.BranchedChat` | Tree-like conversation state with branching support |
| `BranchedLLM.Chat` | ReqLLM-based chat implementation |
| `BranchedLLM.ChatOrchestrator` | Async request orchestration with retry and tool call loops |
| `BranchedLLM.ToolHandler` | Orchestrates tool execution and context injection |
| `BranchedLLM.ToolCache` | Ecto-based tool result caching |
| `BranchedLLM.LLM.StreamParser` | Stream intent detection and tool call extraction |
| `BranchedLLM.LLMErrorFormatter` | User-friendly error message formatting |

### Message Protocol

The `ChatOrchestrator` communicates with the caller via a callback function (`on_event`):

```elixir
{:llm_chunk, branch_id, chunk}        # Streaming text chunk
{:llm_end, branch_id, context_builder} # Stream complete
{:llm_status, branch_id, status}       # Status update ("Thinking...", "Using calculator...")
{:llm_error, branch_id, error_message} # Error occurred
{:update_tool_usage_counts, counts}    # Updated tool usage tracking
```

This allows you to easily pipe events to processes (`send/2`), write directly to STDOUT, or integrate with any other side-effect.


---

## 📚 Guides

- **[Getting Started](guides/getting_started.md)** — Step-by-step tutorial for first-time users
- **[Interactive IEx Tutorial](guides/tutorial_iex.md)** — Hands-on walkthrough in the Elixir shell
- **[Comparison with ReqLLM](guides/comparison_req_llm.md)** — Why use BranchedLLM over raw ReqLLM?

---

## 📄 License

MIT License. See [LICENSE](https://github.com/dvadell/branched_llm/blob/main/LICENSE) for details.
