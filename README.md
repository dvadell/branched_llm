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
    {:branched_llm, "~> 0.1.0"}
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

Configure the LLM connection:

```elixir
config :branched_llm,
  ai_model: "openai:gpt-4o",
  base_url: "http://localhost:11434"
```

Or configure through `:req_llm` (which BranchedLLM falls back to):

```elixir
config :req_llm,
  openai: [
    base_url: "http://localhost:11434/api",
    api_key: "your-api-key"
  ]
```

For tool result caching, configure the Ecto repo:

```elixir
config :branched_llm, BranchedLLM.ToolCache,
  repo: MyApp.Repo
```

You'll also need a `tool_results` table. Generate a migration:

```elixir
def change do
  create table(:tool_results) do
    add :tool_name, :string, null: false
    add :args, :map, null: false
    add :result, :text, null: false
    timestamps()
  end

  create index(:tool_results, [:tool_name, :args])
end
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
  parameters: %{expression: "string"},
  execute: fn %{"expression" => expr} ->
    {result, _} = Code.eval_string(expr)
    {:ok, to_string(result)}
  end
)

{:ok, stream, context_builder, tool_calls} =
  Chat.send_message_stream("What is 123 * 456?", context, tools: [calculator_tool])

# Consume the stream (in a real app, send chunks to your UI)
final_text = Enum.join(stream)
new_context = context_builder.(final_text)
```

### 4. Branching conversations

```elixir
alias BranchedLLM.{BranchedChat, Message}

# Start with an initial conversation
messages = [Message.new(:system, "You are helpful."),
            Message.new(:user, "What is 2+2?"),
            Message.new(:assistant, "2+2 equals 4.")]

branched_chat = BranchedChat.new(Chat, messages, context)

# Branch off from the user's question to explore alternatives
branched_chat = BranchedChat.branch_off(branched_chat, messages |> Enum.at(1) |> Map.get(:id))

# Now the active branch has a different trajectory
branched_chat = BranchedChat.add_user_message(branched_chat, "What is 2*2?")

# Switch back to the main branch
branched_chat = BranchedChat.switch_branch(branched_chat, "main")
```

### 5. Async orchestration (for LiveView / GenServer)

```elixir
alias BranchedLLM.ChatOrchestrator

params = %{
  message: "Tell me about Elixir",
  llm_context: context,
  caller_pid: self(),
  llm_tools: [],
  chat_mod: Chat,
  tool_usage_counts: %{},
  branch_id: "main"
}

{:ok, _task_pid} = ChatOrchestrator.run(params)

# Receive messages in your process:
receive do
  {:llm_chunk, "main", chunk} -> IO.write(chunk)
  {:llm_end, "main", context_builder} -> IO.puts("\nDone!")
  {:llm_status, "main", status} -> IO.puts(status)
  {:llm_error, "main", error} -> IO.puts(error)
end
```

---

## 📖 Architecture

### Core Modules

| Module | Responsibility |
|---|---|
| [`BranchedLLM.Message`](https://hexdocs.pm/branched_llm/BranchedLLM.Message.html) | Immutable message struct with role, content, id, and metadata |
| [`BranchedLLM.BranchedChat`](https://hexdocs.pm/branched_llm/BranchedLLM.BranchedChat.html) | Tree-like conversation state with branching support |
| [`BranchedLLM.ChatBehaviour`](https://hexdocs.pm/branched_llm/BranchedLLM.ChatBehaviour.html) | Behaviour contract (used internally by `BranchedLLM.Chat`) |
| [`BranchedLLM.Chat`](https://hexdocs.pm/branched_llm/BranchedLLM.Chat.html) | ReqLLM-based chat implementation (the default and only provided backend) |
| [`BranchedLLM.ChatOrchestrator`](https://hexdocs.pm/branched_llm/BranchedLLM.ChatOrchestrator.html) | Async request orchestration with retry and tool call loops |
| [`BranchedLLM.ToolHandler`](https://hexdocs.pm/branched_llm/BranchedLLM.ToolHandler.html) | Pure functional tool execution pipeline |
| [`BranchedLLM.ToolCache`](https://hexdocs.pm/branched_llm/BranchedLLM.ToolCache.html) | Ecto-based tool result caching |
| [`BranchedLLM.LLM.StreamParser`](https://hexdocs.pm/branched_llm/BranchedLLM.LLM.StreamParser.html) | Stream intent detection and tool call extraction |
| [`BranchedLLM.LLMErrorFormatter`](https://hexdocs.pm/branched_llm/BranchedLLM.LLMErrorFormatter.html) | User-friendly error message formatting |

### Message Protocol

The `ChatOrchestrator` communicates with the caller via process messages:

```
{:llm_chunk, branch_id, chunk}        # Streaming text chunk
{:llm_end, branch_id, context_builder} # Stream complete
{:llm_status, branch_id, status}       # Status update ("Thinking...", "Using calculator...")
{:llm_error, branch_id, error_message} # Error occurred
{:update_tool_usage_counts, counts}    # Updated tool usage tracking
```

### Data Flow

```
User Input
    │
    ▼
┌──────────────┐
│ BranchedChat │  ← Manages branch state, message queue, active tasks
└──────┬───────┘
       │
       ▼
┌───────────────────┐
│ ChatOrchestrator  │  ← Starts async Task, handles retry, tool call loop
└──────┬────────────┘
       │
       ▼
┌──────────────┐     ┌─────────────┐     ┌──────────────┐
│   Chat       │────▶│ StreamParser│────▶│ ToolHandler  │
│ (ReqLLM)     │     │ (intents)   │     │ (execution)  │
└──────────────┘     └─────────────┘     └──────┬───────┘
                                                │
                                                ▼
                                         ┌──────────────┐
                                         │  ToolCache   │  ← DB-backed cache
                                         └──────────────┘
```

---

## 💡 Why a Behaviour?

`BranchedLLM.ChatBehaviour` exists as a behaviour contract so that `BranchedLLM.Chat` (the included ReqLLM-based implementation) can be tested with mocks in unit tests. It is an internal detail — you will almost certainly just use `BranchedLLM.Chat` directly, which is the only provided implementation.

If you need to talk to an LLM provider that ReqLLM doesn't support, you should either:
1. [Contribute a provider to ReqLLM](https://hex.pm/packages/req_llm), or
2. Use a different library — BranchedLLM is built on top of ReqLLM and depends on its `ReqLLM.Context`, `ReqLLM.Tool`, `ReqLLM.ToolCall`, and `ReqLLM.StreamResponse` types throughout.

---

## 📊 Telemetry Events

| Event | Measure | Metadata |
|---|---|---|
| `[:branched_llm, :ai, :tool, :cache, :hit]` | `:count` (1) | `:tool` (tool name) |
| `[:branched_llm, :ai, :tool, :cache, :miss]` | `:count` (1) | `:tool` (tool name) |

Attach handlers:

```elixir
:telemetry.attach(
  "tool-cache-hit",
  [:branched_llm, :ai, :tool, :cache, :hit],
  fn event, measurements, metadata, config ->
    IO.inspect({event, measurements, metadata})
  end,
  []
)
```

---

## 📚 Guides

- **[Getting Started](guides/getting_started.md)** — Step-by-step tutorial for first-time users
- **[Interactive IEx Tutorial](guides/tutorial_iex.md)** — Hands-on walkthrough in the Elixir shell

---

## 📄 License

MIT License. See [LICENSE](https://github.com/your-org/branched_llm/blob/main/LICENSE) for details.
