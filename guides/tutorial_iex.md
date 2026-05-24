# Interactive IEx Tutorial

This tutorial walks you through every major feature of BranchedLLM using the Elixir interactive shell. You can copy-paste each block directly into `iex -S mix`.

## Setup

Ensure your `config/config.exs` is set up with your LLM provider details (e.g., Ollama or OpenAI). Start your app with IEx:

```bash
iex -S mix
```

All examples below assume you're in the IEx session.

---

## Part 1: Your First Chat

The simplest way to use BranchedLLM is `Chat.send_message/2` — it sends a message and blocks until the full response is ready.

```elixir
alias BranchedLLM.Chat

context = Chat.new_context("You are a helpful assistant")
{:ok, response, new_context} = Chat.send_message("Hello!", context)
```

That's it. `response` is the assistant's reply as a string, and `new_context` contains the updated conversation history (your message + the assistant's reply).

### Continuing the Conversation

Pass `new_context` back in to keep the thread alive:

```elixir
{:ok, response, new_context} = Chat.send_message("What is 2 + 2?", new_context)
```

The context carries the full history, so the LLM remembers what was said before.

### Starting Over

```elixir
fresh = Chat.reset_context(new_context)
# fresh contains only the system prompt — all other messages are gone
```

---

## Part 2: Async with ChatOrchestrator

For streaming responses or non-blocking use, `ChatOrchestrator.run/1` spawns a `Task` that streams events back through an `on_event` callback.

```elixir
alias BranchedLLM.{Chat, ChatOrchestrator}

context = (
  "You are a helpful assistant"
  |> Chat.new_context()
  |> ReqLLM.Context.append(ReqLLM.Context.user("Tell me a short joke"))
)

{:ok, _pid} = ChatOrchestrator.run(%{
  llm_context: context,
  on_event: fn
    {:llm_chunk, _id, chunk} -> IO.write(chunk)
    {:llm_end, _id, _text}   -> IO.puts("\n[Done]")
    {:llm_error, _id, err}   -> IO.puts("\n[Error: #{inspect(err)}]")
    _ -> :ok
  end,
  chat_mod: Chat,
  branch_id: "main"
})
```

You'll see the response appear token-by-token in your terminal. The function returns `{:ok, pid}` immediately — all results come through `on_event`.

> **Note:** When using `ChatOrchestrator` directly, you must append the user message to the context yourself (via `ReqLLM.Context.append/2`). `Chat.send_message/2` does this for you.

### Event Reference

| Event | Description |
|---|---|
| `{:llm_chunk, branch_id, text}` | Streaming text chunk |
| `{:llm_end, branch_id, full_text}` | Stream complete |
| `{:llm_status, branch_id, status}` | Status update (e.g., `"Using calculator..."`) |
| `{:llm_error, branch_id, error}` | Error during the request |
| `{:update_tool_usage_counts, counts}` | Tool invocation counts (for rate limiting) |

---

## Part 3: Tools

Tools let the LLM call your Elixir code. Pass a list of `ReqLLM.Tool` structs via the `:tools` option.

### With ChatOrchestrator (Recommended)

> **Note:** When using tools, prefer `ChatOrchestrator.run/1` over `Chat.send_message/3`.
> Tool calls require two sequential LLM round-trips (one to invoke the tool, one for the
> final answer), which can exceed the synchronous timeout. `ChatOrchestrator` handles
> this naturally via its async event callback.

```elixir
calculator = ReqLLM.Tool.new!(
  name: "calculator",
  description: "Evaluates a mathematical expression",
  parameter_schema: %{
    "type" => "object",
    "properties" => %{
      "expression" => %{"type" => "string", "description" => "The expression to evaluate, e.g. '2 + 2'"}
    },
    "required" => ["expression"]
  },
  callback: fn %{"expression" => expr} ->
    # SECURITY WARNING: Code.eval_string on LLM output is dangerous.
    # In production, use a safe math library or restricted parser.
    try do
      {result, _} = Code.eval_string(expr)
      {:ok, to_string(result)}
    rescue
      e -> {:error, "Failed: #{Exception.message(e)}"}
    end
  end
)

context = (
  "You are a helpful math tutor"
  |> Chat.new_context()
  |> ReqLLM.Context.append(ReqLLM.Context.user("What is 15 × 37?"))
)

ChatOrchestrator.run(%{
  llm_context: context,
  on_event: fn
    {:llm_chunk, _, chunk} -> IO.write(chunk)
    {:llm_status, _, msg} -> IO.puts("\n[#{msg}]")
    {:llm_end, _, text} -> IO.puts("\n[Done]")
    {:llm_error, _, err} -> IO.puts("\n[Error: #{inspect(err)}]")
    _ -> :ok
  end,
  llm_tools: [calculator],
  chat_mod: Chat,
  branch_id: "main"
})
```

You'll see a `[Using calculator...]` status before the final answer streams in.

### With Chat.send_message

```elixir
weather = ReqLLM.Tool.new!(
  name: "get_weather",
  description: "Gets the current weather for a location",
  parameter_schema: %{
    "type" => "object",
    "properties" => %{"location" => %{"type" => "string"}},
    "required" => ["location"]
  },
  callback: fn %{"location" => loc} ->
    {:ok, "72°F, sunny in #{loc}"}
  end
)

context = Chat.new_context("You are a weather assistant")

{:ok, response, _ctx} = Chat.send_message("What's the weather in NYC?", context, tools: [weather])
# The LLM will call the weather tool and include the result in its response
```

> **Warning:** `Chat.send_message/3` has a 60-second timeout. When tools are involved,
> the LLM must make two round-trips (tool call + final response), which can exceed this
> limit with slower providers. Use `ChatOrchestrator` for reliable tool usage.
---

## Part 4: Structured Output (Schemas)

Schemas force the LLM to respond with valid JSON matching your specification. The orchestrator validates the output and automatically retries (up to `schema_max_retries`) if it doesn't conform.

### With Chat.send_message

```elixir
schema = %{
  "type" => "object",
  "properties" => %{
    "sentiment" => %{"type" => "string", "enum" => ["positive", "negative", "neutral"]},
    "confidence" => %{"type" => "number"},
    "keywords" => %{"type" => "array", "items" => %{"type" => "string"}}
  },
  "required" => ["sentiment", "confidence", "keywords"]
}

context = Chat.new_context("You are a sentiment analyzer")
{:ok, result, _ctx} = Chat.send_message(
  "Analyze: 'I absolutely love this product!'",
  context,
  schema: schema
)
# result is a validated map:
# %{"sentiment" => "positive", "confidence" => 0.95, "keywords" => ["love", "product"]}
```

### With ChatOrchestrator

When using schemas with the orchestrator, the `{:llm_end, _, payload}` event delivers the **validated map** instead of raw text:

```elixir
schema = %{
  "type" => "object",
  "properties" => %{
    "invoice_number" => %{"type" => "string"},
    "amount" => %{"type" => "number"},
    "due_date" => %{"type" => "string"}
  },
  "required" => ["invoice_number", "amount", "due_date"]
}

context =
  "You are an invoice parser"
  |> Chat.new_context()
  |> ReqLLM.Context.append(
    ReqLLM.Context.user("Extract: Invoice INV-2024-089 for $450.00 due July 1, 2024")
  )

ChatOrchestrator.run(%{
  llm_context: context,
  on_event: fn
    {:llm_end, _, validated_map} ->
      IO.inspect(validated_map, label: "Structured output")
    {:llm_error, _, %BranchedLLM.StructuredOutput.ValidationError{} = err} ->
      IO.puts("Schema validation exhausted after retries")
      IO.inspect(err)
    {:llm_error, _, other} ->
      IO.inspect(other, label: "Error")
    _ -> :ok
  end,
  chat_mod: Chat,
  branch_id: "main",
  schema: schema,
  schema_max_retries: 3
})
```

If the LLM's first response doesn't match the schema, the orchestrator re-prompts with the validation errors — up to 3 retries in this example (default is 2).

---

## Part 5: Branching Conversations

`BranchedChat` manages a tree of conversation branches. You can fork at any point to explore alternate paths.

```elixir
alias BranchedLLM.{BranchedChat, Chat, Message}

context = Chat.new_context("You are a helpful assistant")
chat = BranchedChat.new(Chat, [], context)

# Add a user message to the current branch
chat = BranchedChat.add_user_message(chat, "What is 2 + 2?")
messages = BranchedChat.get_current_messages(chat)

# Branch off from the first message (start a new topic)
branch_point_id = List.first(messages).id
chat = BranchedChat.branch_off(chat, branch_point_id)

# We're now on a new branch
chat.current_branch_id   #=> "some-uuid-..."
chat.branch_ids          #=> ["main", "some-uuid-..."]

# Add a different follow-up on this new branch
chat = BranchedChat.add_user_message(chat, "Tell me a story about space.")

# Switch back to main
chat = BranchedChat.switch_branch(chat, "main")
```

### Branch Tree

```elixir
tree = BranchedChat.build_tree(chat)
```

---

## Part 6: Message Queue and Busy State

`BranchedChat` tracks whether a branch is actively processing an LLM response and queues additional messages.

```elixir
# Initially, the branch is not busy
BranchedChat.busy?(chat, "main") #=> false

# Mark the branch as busy (e.g., when an LLM Task starts)
chat = BranchedChat.set_active_task(chat, "main", self(), "Hello")
BranchedChat.busy?(chat, "main") #=> true

# While busy, you can enqueue messages
chat = BranchedChat.enqueue_message(chat, "main", "Are you there?")

# Dequeue when ready
{next, chat} = BranchedChat.dequeue_message(chat, "main")
#=> {"Are you there?", ...}

# Clear the active task
chat = BranchedChat.clear_active_task(chat, "main")
```

---

## Part 7: Messages

The `Message` struct is the fundamental building block for `BranchedChat`. Every conversation message has a role, content, and unique ID.

```elixir
alias BranchedLLM.Message

# Create messages
sys = Message.new(:system, "You are a helpful assistant.")
user = Message.new(:user, "Hello, how are you?")
assistant = Message.new(:assistant, "I'm doing great!")

# Messages have unique IDs
user.id  #=> "a1b2c3d4-..."

# Custom ID
msg = Message.new(:user, "Custom ID", id: "my-id")
msg.id   #=> "my-id"

# Add metadata (useful for tool calls, annotations, etc.)
msg_with_meta = Message.new(:assistant, "Response", nil, %{tool_calls: [%{id: "tc1", name: "search"}]})

# Soft delete
deleted = Message.mark_deleted(user)
Message.deleted?(deleted)  #=> true

# Convert to/from legacy map format
map = Message.to_map(user)
#=> %{sender: :user, content: "Hello, how are you?", id: "...", deleted: false}
restored = Message.from_map(map)
```

> **Note:** `BranchedLLM.Message` is used by `BranchedChat`. Under the hood, `Chat` and `ChatOrchestrator` work with `ReqLLM.Message` inside `ReqLLM.Context`. You typically don't need to construct `ReqLLM.Message` directly — use `Chat.new_context/1`, `ReqLLM.Context.user/1`, etc.

---

## Part 8: Context Window Management

Long conversations can exceed the LLM's token limit (e.g., 128k for GPT-4), causing API errors. `ContextManager` prevents this by automatically trimming the context.

### Estimating Token Count

```elixir
alias BranchedLLM.ContextManager

context = Chat.new_context("You are a helpful assistant")
ContextManager.estimate_tokens(context)          #=> 7
ContextManager.estimate_tokens(context, chars_per_token: 2)  #=> 14
```

### Automatic Trimming

Configure a max token limit and trimming happens automatically before LLM calls:

```elixir
# In config/config.exs
config :branched_llm, max_tokens: 128_000

# Or per-call:
context = ReqLLM.Context.append(context, ReqLLM.Context.user("Hello!"))
Chat.send_message_stream(context, max_tokens: 50_000)
```

### Manual Trimming

```elixir
context = Chat.new_context("You are a helpful assistant")
context = ReqLLM.Context.append(context, ReqLLM.Context.user("First question"))
context = ReqLLM.Context.append(context, ReqLLM.Context.assistant("First answer"))
context = ReqLLM.Context.append(context, ReqLLM.Context.user("Second question"))

# Trim to fit a small limit
{trimmed, was_trimmed} = ContextManager.trim(context, max_tokens: 5)
was_trimmed  #=> true

# System messages are always preserved
# The most recent messages are kept
```

### Built-in Strategies

```elixir
alias BranchedLLM.ContextManager.Strategy

# Prune: drop oldest messages until context fits (default fallback)
Strategy.Prune.trim(context, max_tokens: 5)

# SlidingWindow: keep only the last N conversation messages
Strategy.SlidingWindow.trim(context, keep: 4)

# Percentage: keep the last 70% of conversation tokens
Strategy.Percentage.trim(context, retain: 0.7)

# Summarize: condense older messages into a single summary
Strategy.Summarize.trim(context, recent_count: 4)
```

Configure a strategy globally:

```elixir
# In config/config.exs
config :branched_llm,
  max_tokens: 128_000,
  trim_callback: {BranchedLLM.ContextManager.Strategy.SlidingWindow, :trim, [keep: 20]}
```

Or per-call:

```elixir
ContextManager.trim(context,
  max_tokens: 128_000,
  trim_callback: {Strategy.SlidingWindow, :trim, [keep: 10]}
)
```

### Custom Strategy

Implement the `Strategy` behaviour for your own trimming logic:

```elixir
defmodule MyApp.Strategy.KeepRecent do
  @behaviour BranchedLLM.ContextManager.Strategy

  @impl true
  def trim(context, opts) do
    keep = Keyword.get(opts, :keep, 10)
    system = Enum.filter(context.messages, &(&1.role == :system))
    conversation = Enum.reject(context.messages, &(&1.role == :system))
    recent = Enum.take(conversation, -keep)
    %{context | messages: system ++ recent}
  end
end
```

Then use it:

```elixir
ContextManager.trim(context,
  max_tokens: 128_000,
  trim_callback: {MyApp.Strategy.KeepRecent, :trim, [keep: 20]}
)
```

---

## Part 9: Error Handling

```elixir
alias BranchedLLM.LLMErrorFormatter

# Simulate a rate limit error
rate_error = %ReqLLM.Error.API.Request{
  status: 429,
  reason: "Too many requests",
  response_body: %{
    "details" => [%{"@type" => "...", "retryDelay" => "30s"}]
  }
}

LLMErrorFormatter.format(rate_error)
#=> "The AI is busy. Wait a moment and try again later. Please retry in 30s."
```

---

## Part 10: Putting It All Together — A Mini-App

A quick REPL loop in IEx:

```elixir
defmodule IExChat do
  alias BranchedLLM.Chat

  def start do
    context = Chat.new_context("You are a concise assistant.")
    loop(context)
  end

  defp loop(context) do
    case IO.gets("\nYou> ") |> String.trim() do
      "quit" -> :ok
      input  ->
        IO.write("AI> ")
        {:ok, response, new_context} = Chat.send_message(input, context)
        IO.puts(response)
        loop(new_context)
    end
  end
end

IExChat.start()
```

---

## Summary

| Concept | Module | Key Functions |
|---|---|---|
| Chat | `BranchedLLM.Chat` | `new_context/1`, `send_message/2,3`, `reset_context/1` |
| Orchestration | `BranchedLLM.ChatOrchestrator` | `run/1` |
| Tools | `ReqLLM.Tool` | `new!/1` (pass via `:tools` option) |
| Structured Output | `BranchedLLM.Chat` / `ChatOrchestrator` | pass `schema:` option |
| Branching | `BranchedLLM.BranchedChat` | `branch_off/2`, `switch_branch/2` |
| Messages | `BranchedLLM.Message` | `new/3`, `mark_deleted/1` |
| Context Window | `BranchedLLM.ContextManager` | `trim/2`, `estimate_tokens/2` |
| Errors | `BranchedLLM.LLMErrorFormatter` | `format/1` |
| Caching | `BranchedLLM.ToolCache` | `get_result/2`, `save_result/3` |

---

## Next Steps

- **[Getting Started Guide](getting_started.md)** — In-depth feature walkthrough
- **[API Reference](https://hexdocs.pm/branched_llm)** — Full module documentation
- **[Source Code](https://github.com/dvadell/branched_llm)** — Read the implementation
