# Getting Started

This guide walks you through using BranchedLLM — a wrapper around [ReqLLM](https://hex.pm/packages/req_llm) — to build LLM-powered applications with branching conversations, tool execution, and streaming responses.

> **Note:** BranchedLLM is built on top of ReqLLM and uses its types (`ReqLLM.Context`, `ReqLLM.Tool`, `ReqLLM.StreamResponse`, etc.) throughout. If you need an LLM provider that ReqLLM doesn't support, consider [contributing to ReqLLM](https://hex.pm/packages/req_llm) first.

## Prerequisites

- Elixir ~> 1.15
- An LLM API endpoint (Ollama, OpenAI, etc.)
- Basic familiarity with Elixir

---

## Step 1: Installation

Add BranchedLLM to your `mix.exs`:

```elixir
def deps do
  [
    {:branched_llm, "~> 0.1.1"},
    {:req_llm, "~> 1.13.0"},
    {:ecto, "~> 3.13"}
  ]
end
```

Configure your LLM provider in `config/config.exs`:

```elixir
config :branched_llm,
  ai_model: "ollama:cara-cpu",
  base_url: "http://localhost:11434"
```

If you're using Ollama locally, the `base_url` points to your local instance. For cloud providers, set your API key through `:req_llm`:

```elixir
config :req_llm,
  openai: [
    base_url: "https://api.openai.com",
    api_key: System.get_env("OPENAI_API_KEY")
  ]
```

---

## Step 2: Basic Chat

The simplest use case is sending a message and getting a response:

```elixir
alias BranchedLLM.Chat

# Create a context with a system prompt
context = Chat.new_context("You are a helpful assistant.")

# Send a message
{:ok, response, new_context} = Chat.send_message("What is Elixir?", context)
IO.puts(response)
```

`Chat.send_message/3` returns the complete response text. Internally, it streams tokens but collects them before returning.

### Streaming

For real-time UI updates, use `send_message_stream/2`:

```elixir
alias BranchedLLM.LLM.StreamResult.ContentResult

context_with_msg = ReqLLM.Context.append(context, ReqLLM.Context.user("Tell me a story"))

{:ok, %ContentResult{stream: stream}} =
  Chat.send_message_stream(context_with_msg)

# Consume the stream token by token
stream
|> ReqLLM.StreamResponse.tokens()
|> Enum.each(fn chunk ->
  IO.write(chunk)
end)

IO.puts("")

# Build the final context with the assistant's complete response
final_text = Enum.map_join(ReqLLM.StreamResponse.tokens(stream), & &1)
new_context = ReqLLM.Context.append(context_with_msg, ReqLLM.Context.assistant(final_text))
```

The caller is responsible for appending the user message beforehand and appending the final assistant text to the context when the stream is complete.

---

## Step 3: Branching Conversations

One of BranchedLLM's standout features is the ability to fork conversations at any point.

### Creating a BranchedChat

```elixir
alias BranchedLLM.{BranchedChat, Message}

# Start with some initial messages (system prompt lives in the context, not the message list)
messages = [
  Message.new(:user, "What programming languages do you know about?"),
  Message.new(:assistant, "I know many languages including Elixir, Python, Rust, and more!")
]

context = Chat.new_context("You are a helpful assistant.")
branched_chat = BranchedChat.new(Chat, messages, context)
```

### Adding Messages

```elixir
# Add a user message to the current branch
branched_chat = BranchedChat.add_user_message(branched_chat, "Tell me about Elixir")

# Get current messages
messages = BranchedChat.get_current_messages(branched_chat)
```

### Branching Off

```elixir
# Branch off from the user's first question
user_message_id = messages |> Enum.at(1) |> Map.get(:id)
branched_chat = BranchedChat.branch_off(branched_chat, user_message_id)

# Now we're on a new branch. The user message we added earlier
# is NOT on this new branch — only messages up to the branch point.
messages = BranchedChat.get_current_messages(branched_chat)
# => [system message, user message about programming languages]

# Add a different follow-up on this branch
branched_chat = BranchedChat.add_user_message(branched_chat, "What about Rust?")
```

### Switching Branches

```elixir
# List all branches
branched_chat.branch_ids
# => ["main", "some-uuid-here", ...]

# Switch back to main
branched_chat = BranchedChat.switch_branch(branched_chat, "main")

# Build a tree view of all branches
tree = BranchedChat.build_tree(branched_chat)
# => [%{id: "main", children: [%{id: "...", children: []}]}]
```

### Deleting Messages

```elixir
# Soft-delete a message (it stays in history but is excluded from context)
message_id = List.last(BranchedChat.get_current_messages(branched_chat)).id
branched_chat = BranchedChat.delete_message(branched_chat, message_id)

# Check if a message is deleted
message = BranchedChat.get_current_messages(branched_chat) |> Enum.find(&(&1.id == message_id))
Message.deleted?(message)
# => true
```

---

## Step 4: Tool Calling

Tools let the LLM call your code to perform actions like calculations, searches, or database lookups.

### Defining a Tool

```elixir
calculator_tool = ReqLLM.Tool.new!(
  name: "calculator",
  description: "Evaluates a mathematical expression and returns the result",
  parameter_schema: %{
    type: "object",
    properties: %{
      expression: %{
        type: "string",
        description: "The mathematical expression to evaluate, e.g. '2 + 2'"
      }
    },
    required: ["expression"]
  },
  callback: fn %{"expression" => expr} ->
    # SECURITY WARNING: Using Code.eval_string on LLM output is dangerous.
    # In a production app, use a safe math library or a restricted parser.
    try do
      {result, _} = Code.eval_string(expr)
      {:ok, to_string(result)}
    rescue
      e -> {:error, "Failed to evaluate: #{Exception.message(e)}"}
    end
  end
)
```

### Using Tools in Chat

```elixir
context = Chat.new_context("You are a helpful assistant. Use the calculator when needed.")

{:ok, result} =
  Chat.send_message_stream("What is 847 * 392?", context, tools: [calculator_tool])

# result is either %ContentResult{} or %ToolCallResult{}

# If the LLM decides to use the calculator:
# 1. It returns a tool call instead of text
# 2. The tool is executed
# 3. The result is added to context
# 4. The LLM is called again to produce a final answer

# ChatOrchestrator handles this entire loop automatically.
```

### Tool Execution Pipeline

The full tool call loop is handled by `ChatOrchestrator`:

1. LLM receives user message + available tools
2. LLM decides to call a tool → returns `tool_calls`
3. `ToolHandler` executes each tool, appends results to context
4. LLM receives tool results and produces final answer
5. If the LLM calls more tools, the loop repeats (up to 10 calls per tool)

### Tool Result Caching

Tool results are automatically cached to avoid redundant API/database calls:

```elixir
# Configure the cache
config :branched_llm, BranchedLLM.ToolCache,
  repo: MyApp.Repo

# First call executes the tool and saves to DB
# Second call with same args returns cached result
BranchedLLM.ToolCache.get_result("calculator", %{"expression" => "2+2"})
# => {:ok, "4"}
```

### Telemetry Events

Tool cache events are emitted via `:telemetry`:

```elixir
:telemetry.attach(
  "tool-cache-hit",
  [:branched_llm, :ai, :tool, :cache, :hit],
  fn _event, measurements, metadata, _config ->
    IO.puts("Cache HIT for tool: #{metadata.tool}")
  end,
  []
)
```

---

## Step 5: Async Orchestration (LiveView Integration)

For web interfaces, you don't want to block the UI while waiting for the LLM. `ChatOrchestrator` runs the LLM request in a separate `Task` and communicates via messages.

### Starting the Orchestrator

```elixir
alias BranchedLLM.ChatOrchestrator

caller_pid = self()
# llm_context holds the conversation history (system prompt + past messages).
# The user message must be appended to the context before calling the orchestrator.
llm_context = ReqLLM.Context.append(context, ReqLLM.Context.user("What is Elixir?"))
params = %{
  llm_context: llm_context,
  # on_event is a function that receives orchestrator events.
  # Typically, it sends them back to the caller pid:
  on_event: fn event -> send(caller_pid, event) end,
  llm_tools: [calculator_tool],
  chat_mod: Chat,
  tool_usage_counts: %{"calculator" => 0},
  branch_id: "main"
}

{:ok, _task_pid} = ChatOrchestrator.run(params)
```

### Receiving Messages

Your process (LiveView, GenServer, etc.) receives messages:

```elixir
def handle_info({:llm_chunk, branch_id, chunk}, socket) do
  # Append chunk to the streaming message in the UI
  {:noreply, stream_insert(socket, :chunks, chunk)}
end

def handle_info({:llm_end, _branch_id, full_text}, socket) do
  # Stream complete — append final assistant response to the context
  new_context = ReqLLM.Context.append(socket.assigns.context, ReqLLM.Context.assistant(full_text))
  {:noreply, assign(socket, :context, new_context)}
end

def handle_info({:llm_status, branch_id, status}, socket) do
  # Show status: "Thinking...", "Using calculator..."
  {:noreply, assign(socket, :status, status)}
end

def handle_info({:llm_error, branch_id, error}, socket) do
  # Display error to user
  {:noreply, assign(socket, :error, error)}
end

def handle_info({:update_tool_usage_counts, counts}, socket) do
  {:noreply, assign(socket, :tool_usage_counts, counts)}
end
```

### Message Queue

`BranchedChat` supports a built-in message queue for when the LLM is busy:

```elixir
# If the branch is busy, enqueue the message
if BranchedChat.busy?(branched_chat, "main") do
  branched_chat = BranchedChat.enqueue_message(branched_chat, "main", "Follow-up question")
end

# When the current response finishes, dequeue:
{next_message, branched_chat} = BranchedChat.dequeue_message(branched_chat, "main")

if next_message do
  # Add the next user message to the context and start the orchestrator
  next_context = ReqLLM.Context.append(params.llm_context, ReqLLM.Context.user(next_message))
  ChatOrchestrator.run(%{params | llm_context: next_context})
end
```

---

## Step 6: Understanding the Architecture

BranchedLLM is a **wrapper around ReqLLM**, not a generic LLM abstraction layer. The `BranchedLLM.ChatBehaviour` behaviour exists primarily so that `BranchedLLM.Chat` can be mocked in tests. In practice, you will always use `BranchedLLM.Chat` directly.

Here's how the pieces fit together:

```
┌──────────────────────────────────────────┐
│            Your Application              │
│   (LiveView, CLI, GenServer, etc.)       │
├──────────────────────────────────────────┤
│         BranchedLLM                      │
│   ┌────────────────────────────┐         │
│   │   BranchedChat             │  Branch  │
│   │   + Message queue          │  mgmt    │
│   └──────────┬─────────────────┘         │
│              │                           │
│   ┌──────────▼─────────────────┐         │
│   │   ChatOrchestrator         │  Async   │
│   │   + Retry + tool loop      │  orchest │
│   └──────────┬─────────────────┘         │
│             │                            │
│  ┌──────────▼─────────────────┐          │
│  │ ContextManager              │ Window   │
│  │ + Token estimation          │ mgmt     │
│  │ + Trim/prune/summarize      │          │
│  └──────────┬─────────────────┘          │
│             │                            │
│  ┌──────────▼─────────────────┐          │
│  │ Chat                       │ ReqLLM   │
│  │ (ReqLLM-based)             │ wrapper  │
│  └──────────┬─────────────────┘          │
│   └──────────┬─────────────────┘         │
├──────────────┼───────────────────────────┤
│              │    ReqLLM                  │
│   ┌──────────▼─────────────────┐         │
│   │   ReqLLM.stream_text/3     │  HTTP    │
│   │   ReqLLM.Tool              │  client  │
│   │   ReqLLM.Context           │          │
│   └────────────────────────────┘         │
└──────────────────────────────────────────┘
```

All LLM API communication goes through ReqLLM. BranchedLLM adds:
- **Branching**: fork conversations at any point
- **Orchestration**: async tasks, retries, message queuing
- **Context management**: automatic token limit enforcement and trimming
- **Tool loop**: detect → execute → inject → repeat
- **Streaming protocol**: clean message protocol for your UI

---

## Step 7: Context Window Management

As conversations grow, the accumulated messages can exceed the LLM's context window (e.g., 128k tokens for GPT-4), causing the API to return a 400 error. BranchedLLM provides `ContextManager` to prevent this.

### Setting a Token Limit

Configure a max token limit in `config/config.exs`:

```elixir
config :branched_llm,
  max_tokens: 128_000
```

When the context exceeds this limit before an LLM call, the oldest non-system messages are automatically removed until it fits. System messages are always preserved.

You can also set the limit per-call:

```elixir
Chat.send_message_stream("Hello!", context, max_tokens: 50_000)
```

Or disable trimming entirely (the default):

```elixir
Chat.send_message_stream("Hello!", context, max_tokens: :infinity)
```

### Built-in Strategies

BranchedLLM ships four strategies. Configure them using a `{module, function, opts}` tuple:

| Strategy | Description | Key option |
|---|---|---|
| `Strategy.Prune` | Drop oldest non-system messages until context fits (default) | — |
| `Strategy.SlidingWindow` | Keep only the last N messages | `keep: N` |
| `Strategy.Percentage` | Keep the last X% of conversation tokens | `retain: 0.7` |
| `Strategy.Summarize` | Condense older messages into a summary | `recent_count: 4` |

```elixir
# Keep last 20 conversation messages
config :branched_llm,
  max_tokens: 128_000,
  trim_callback: {BranchedLLM.ContextManager.Strategy.SlidingWindow, :trim, [keep: 20]}

# Keep last 70% of conversation tokens
config :branched_llm,
  max_tokens: 128_000,
  trim_callback: {BranchedLLM.ContextManager.Strategy.Percentage, :trim, [retain: 0.7]}

# Summarize older messages (keep last 4 intact)
config :branched_llm,
  max_tokens: 128_000,
  trim_callback: {BranchedLLM.ContextManager.Strategy.Summarize, :trim, [recent_count: 4]}
```

Or per-call:

```elixir
Chat.send_message_stream("Hello!", context,
  max_tokens: 50_000,
  trim_callback: {BranchedLLM.ContextManager.Strategy.SlidingWindow, :trim, [keep: 10]}
)
```

If the strategy result still exceeds `max_tokens`, `Strategy.Prune` is applied as a fallback.

### Custom Strategies

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

### How It Works

`ContextManager.trim/2` is called automatically at two points:

1. **Before LLM calls** — `Chat.send_message_stream/2` trims the context before sending it to the LLM. The untrimmed history is preserved in `BranchedChat` (or your application state), so when `finish_ai_response/3` is called with the final `full_text`, the full conversation history is stored.

2. **After context rebuilds** — `BranchedChat.rebuild_context_from_messages/2` trims the rebuilt context after `branch_off` or `delete_message` operations.

This means trimming only affects what the LLM sees — your UI still has access to the complete message history.

### Token Estimation

`ContextManager` estimates tokens using a character-based heuristic (~4 characters per token for English text). This is conservative and sufficient for preventing overflow:

```elixir
alias BranchedLLM.ContextManager

context = Chat.new_context("You are a helpful assistant.")
ContextManager.estimate_tokens(context)  #=> estimated token count

# Adjust the heuristic for CJK text (~1.5-2 chars/token)
ContextManager.estimate_tokens(context, chars_per_token: 2)
```

For precise token counting, provide a custom `trim_callback` that uses the model's tokenizer.

---

## Step 8: Error Handling

BranchedLLM provides user-friendly error messages:

```elixir
try do
  Chat.send_message("Hello", context)
rescue
  e ->
    friendly_message = BranchedLLM.LLMErrorFormatter.format(e)
    # => "The AI is busy. Wait a moment and try again later."
    # => "API error (status 429). Please try again."
    # => "API error (status 500). Please try again."
end
```

Rate limit errors (429) include retry delay information when the API provides it:

```
"The AI is busy. Wait a moment and try again later. Please retry in 30s."
```

---

## Next Steps

- **[Interactive IEx Tutorial](tutorial_iex.md)** — A hands-on walkthrough in the Elixir shell
- **[API Reference](https://hexdocs.pm/branched_llm)** — Full module documentation
- **[Source Code](https://github.com/dvadell/branched_llm)** — Read the implementation
