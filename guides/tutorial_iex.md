# Interactive IEx Tutorial

This tutorial walks you through every major feature of BranchedLLM using the Elixir interactive shell. You can copy-paste each block directly into `iex -S mix`.

## Setup

Ensure your `config/config.exs` is set up with your LLM provider details (e.g., Ollama or OpenAI).

Start your app with IEx:

```bash
iex -S mix
```

All examples below assume you're in the IEx session.

---

## Part 1: Messages

The `Message` struct is the fundamental building block. Every conversation message has a role, content, and unique ID.

```elixir
alias BranchedLLM.Message

# Create a system message
sys = Message.new(:system, "You are a helpful assistant.")
#=> %BranchedLLM.Message{role: :system, content: "You are a helpful assistant.", id: "...", metadata: %{}}

# Create a user message
user = Message.new(:user, "Hello, how are you?")
#=> %BranchedLLM.Message{role: :user, content: "Hello, how are you?", id: "...", metadata: %{}}

# Create an assistant message
assistant = Message.new(:assistant, "I'm doing great! How can I help you today?")

# Messages have unique IDs
user.id
#=> "a1b2c3d4-..."

# You can provide a custom ID
custom_msg = Message.new(:user, "Custom ID", id: "my-custom-id")
custom_msg.id
#=> "my-custom-id"

# Add metadata (useful for tool calls, annotations, etc.)
msg_with_meta = Message.new(:assistant, "Response", nil, %{tool_calls: [%{id: "tc1", name: "search"}]})

# Mark a message as deleted (soft delete)
deleted = Message.mark_deleted(user)
Message.deleted?(deleted)
#=> true

# Convert to/from legacy map format
map = Message.to_map(user)
#=> %{sender: :user, content: "Hello, how are you?", id: "...", deleted: false}

restored = Message.from_map(map)
```

---

## Part 2: Basic Chat with BranchedChat

`BranchedChat` manages a tree of conversation branches. Let's start with a single "main" branch.

```elixir
alias BranchedLLM.{BranchedChat, Message, Chat}

# The system prompt lives in the ReqLLM.Context — no need to duplicate
# it in the messages list (system-role messages are skipped during context rebuild).
context = Chat.new_context("You are a helpful assistant.")

# Create the branched chat with an empty message list
chat = BranchedChat.new(Chat, [], context)

# Add a user message to the current branch
chat = BranchedChat.add_user_message(chat, "What is 2 + 2?")

# Get messages from the current branch
BranchedChat.get_current_messages(chat)
```

---

## Part 3: Branching Conversations

This is where BranchedLLM shines. You can fork any conversation at any message.

```elixir
# Let's see the current messages
messages = BranchedChat.get_current_messages(chat)

# Branch off from the system message (start a new topic)
branch_point_id = List.first(messages).id

chat = BranchedChat.branch_off(chat, branch_point_id)

# We're now on a new branch!
chat.current_branch_id
#=> "some-uuid-..."

chat.branch_ids
#=> ["main", "some-uuid-..."]

# The new branch only has messages up to the branch point (just the system message)
BranchedChat.get_current_messages(chat)

# Add a DIFFERENT follow-up on this new branch
chat = BranchedChat.add_user_message(chat, "Tell me a story about space.")

# Now switch back to main
chat = BranchedChat.switch_branch(chat, "main")
```

### Branch Tree

```elixir
# View the full tree structure
tree = BranchedChat.build_tree(chat)
```

---

## Part 4: Message Queue and Busy State

BranchedChat tracks whether a branch is actively processing an LLM response and queues additional messages.

```elixir
# Initially, the branch is not busy
BranchedChat.busy?(chat, "main")
#=> false

# Simulate setting an active task (e.g., an LLM Task PID)
chat = BranchedChat.set_active_task(chat, "main", self(), "Hello")

BranchedChat.busy?(chat, "main")
#=> true

# While busy, you can enqueue messages
chat = BranchedChat.enqueue_message(chat, "main", "Are you there?")

# Dequeue messages when ready
{next, chat} = BranchedChat.dequeue_message(chat, "main")
#=> {"Are you there?", ...}

# Clear the active task
chat = BranchedChat.clear_active_task(chat, "main")
```

---

## Part 5: Tools

Tools allow the LLM to call your code. Let's create a calculator tool.

```elixir
calculator = ReqLLM.Tool.new!(
  name: "calculator",
  description: "Evaluates a mathematical expression",
  parameter_schema: %{
    type: "object",
    properties: %{
      expression: %{
        type: "string",
        description: "The expression to evaluate, e.g. '2 + 2'"
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
      e -> {:error, "Failed: #{Exception.message(e)}"}
    end
  end
)
```

---

## Part 6: Real-world Orchestration

The `ChatOrchestrator` runs the LLM request in a separate `Task`. In IEx, we can use a helper function to "listen" for the streaming chunks.

### Run a Real Request

The `on_event` function can be used to handle streaming updates directly. In this example, we'll write to STDOUT:

```elixir
alias BranchedLLM.{Chat, ChatOrchestrator}

# llm_context holds the conversation history (system prompt + past messages).
# The user message must be appended to the context before calling the orchestrator.
context = (
  "You are a helpful assistant."
  |> Chat.new_context()
  |> ReqLLM.Context.append(ReqLLM.Context.user("What is 123 * 456?"))
)

params = %{
  llm_context: context,
  on_event: fn
    {:llm_chunk, _id, chunk} -> IO.write(chunk)
    {:llm_status, _id, status} -> IO.puts("\n[Status: #{status}]")
    {:llm_end, _id, _full_text} -> IO.puts("\n[Stream Complete]")
    {:llm_error, _id, err} -> IO.puts("\n[Error: #{err}]")
    {:update_tool_usage_counts, _counts} -> :ok
  end,
  chat_mod: Chat,
  branch_id: "main"
}

# Start the async orchestrator
{:ok, _task_pid} = ChatOrchestrator.run(params)
```

You will see the output appearing in your IEx session as the AI responds!


---

## Part 7: Error Handling

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

## Part 8: Context Window Management

Long conversations can exceed the LLM's token limit (e.g., 128k for GPT-4), causing API errors. `ContextManager` prevents this by automatically trimming the context.

### Estimating Token Count

```elixir
alias BranchedLLM.ContextManager

context = Chat.new_context("You are a helpful assistant.")

# Estimate how many tokens the context currently uses
ContextManager.estimate_tokens(context)
#=> 7

# Adjust the heuristic for CJK text (~1.5-2 chars/token)
ContextManager.estimate_tokens(context, chars_per_token: 2)
#=> 14
```

### Automatic Trimming

Configure a max token limit and trimming happens automatically before LLM calls:

```elixir
# In config/config.exs
config :branched_llm, max_tokens: 128_000

# Or per-call:
context_with_msg = ReqLLM.Context.append(context, ReqLLM.Context.user("Hello!"))
Chat.send_message_stream(context_with_msg, max_tokens: 50_000)
```

### Manual Trimming

You can also call `trim/2` directly to inspect or control trimming:

```elixir
# Build a large context
context = Chat.new_context("You are a helpful assistant.")
context = ReqLLM.Context.append(context, ReqLLM.Context.user("First question"))
context = ReqLLM.Context.append(context, ReqLLM.Context.assistant("First answer"))
context = ReqLLM.Context.append(context, ReqLLM.Context.user("Second question"))

# Trim to fit within a small limit
{trimmed, was_trimmed} = ContextManager.trim(context, max_tokens: 5)
was_trimmed
#=> true

# System messages are always preserved
Enum.filter(trimmed.messages, fn msg -> msg.role == :system end)
#=> [%ReqLLM.Message{role: :system, ...}]

# The most recent messages are kept
List.last(trimmed.messages).role
#=> :user
```

### Built-in Strategies

BranchedLLM ships four strategies under `BranchedLLM.ContextManager.Strategy.*`:

```elixir
alias BranchedLLM.ContextManager.Strategy

# Prune: drop oldest messages until context fits (default fallback)
trimmed = Strategy.Prune.trim(context, max_tokens: 5)

# SlidingWindow: keep only the last N conversation messages
trimmed = Strategy.SlidingWindow.trim(context, keep: 4)

# Percentage: keep the last 70% of conversation tokens
trimmed = Strategy.Percentage.trim(context, retain: 0.7)

# Summarize: condense older messages into a single summary
trimmed = Strategy.Summarize.trim(context, recent_count: 4)
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
    system = Enum.filter(context.messages, fn msg -> msg.role == :system end)
    conversation = Enum.reject(context.messages, fn msg -> msg.role == :system end)
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

## Part 9: Putting It All Together — A Mini-App

You can run the built-in sample chat directly to see everything in action:

```elixir
# If you have the sample_chat.ex file:
# c "sample_chat.ex"
# SampleChat.start()
```

Or implement a quick loop in IEx:

```elixir
defmodule IExChat do
  alias BranchedLLM.{BranchedChat, Message, Chat}

  def start do
    context = Chat.new_context("You are a concise assistant.")
    chat = BranchedChat.new(Chat, [], context)
    loop(chat)
  end

  defp loop(chat) do
    input = IO.gets("\nYou> ") |> String.trim()
    if input == "quit", do: :ok, else: send_and_wait(chat, input)
  end

  defp send_and_wait(chat, input) do
    chat = BranchedChat.add_user_message(chat, input)
    IO.write("AI> ")
    {:ok, response, new_context} = Chat.send_message(input, BranchedChat.get_current_context(chat))
    IO.puts(response)
    
    # Update branch state manually for this simple example
    updated_branch = %{chat.branches["main"] | context: new_context, messages: chat.branches["main"].messages ++ [Message.new(:assistant, response)]}
    loop(%{chat | branches: %{"main" => updated_branch}})
  end
end

# IExChat.start()
```

---

## Summary

| Concept | Module | Key Functions |
|---|---|---|
| Messages | `BranchedLLM.Message` | `new/3`, `mark_deleted/1` |
| Branching | `BranchedLLM.BranchedChat` | `branch_off/2`, `switch_branch/2` |
| Chat | `BranchedLLM.Chat` | `send_message/3`, `send_message_stream/2` |
| Orchestration | `BranchedLLM.ChatOrchestrator` | `run/1` |
| Context Window | `BranchedLLM.ContextManager` | `trim/2`, `estimate_tokens/2` |
| Errors | `BranchedLLM.LLMErrorFormatter` | `format/1` |
| Caching | `BranchedLLM.ToolCache` | `get_result/2`, `save_result/3` |

---

## Next Steps

- **[Getting Started Guide](getting_started.md)** — In-depth feature walkthrough
- **[API Reference](https://hexdocs.pm/branched_llm)** — Full module documentation
- **[Source Code](https://github.com/dvadell/branched_llm)** — Read the implementation
