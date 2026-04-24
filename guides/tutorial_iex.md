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

# Create initial messages
messages = [
  Message.new(:system, "You are a helpful assistant.")
]

# Create a context
context = Chat.new_context("You are a helpful assistant.")

# Create the branched chat
chat = BranchedChat.new(Chat, messages, context)

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
calculator = ReqLLM.Tool.new(
  name: "calculator",
  description: "Evaluates a mathematical expression",
  parameters: %{
    type: "object",
    properties: %{
      expression: %{
        type: "string",
        description: "The expression to evaluate, e.g. '2 + 2'"
      }
    },
    required: ["expression"]
  },
  execute: fn %{"expression" => expr} ->
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

### Setup a Listener

Define this helper in your IEx session to handle the async protocol:

```elixir
listen = fn listen ->
  receive do
    {:llm_chunk, _id, chunk} -> 
      IO.write(if is_map(chunk), do: chunk.text, else: chunk)
      listen.(listen)
    {:llm_status, _id, status} -> 
      IO.puts("\n[Status: #{status}]")
      listen.(listen)
    {:llm_end, _id, _builder} -> 
      IO.puts("\n[Stream Complete]")
    {:llm_error, _id, err} -> 
      IO.puts("\n[Error: #{err}]")
    {:update_tool_usage_counts, _counts} ->
      listen.(listen)
  after
    10000 -> IO.puts("\n[Timed out waiting for AI]")
  end
end
```

### Run a Real Request

```elixir
alias BranchedLLM.{Chat, ChatOrchestrator}

context = Chat.new_context("You are a helpful assistant.")

params = %{
  message: "What is 123 * 456?",
  llm_context: context,
  caller_pid: self(),
  llm_tools: [calculator],
  chat_mod: Chat,
  tool_usage_counts: %{},
  branch_id: "main"
}

# Start the async orchestrator
{:ok, _task_pid} = ChatOrchestrator.run(params)

# Run the listener to see the output in real-time
listen.(listen)
```

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

## Part 8: Putting It All Together — A Mini-App

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
    chat = BranchedChat.new(Chat, [Message.new(:system, "You are a concise assistant.")], context)
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
| Chat | `BranchedLLM.Chat` | `send_message/3`, `send_message_stream/3` |
| Orchestration | `BranchedLLM.ChatOrchestrator` | `run/1` |
| Errors | `BranchedLLM.LLMErrorFormatter` | `format/1` |
| Caching | `BranchedLLM.ToolCache` | `get_result/2`, `save_result/3` |

---

## Next Steps

- **[Getting Started Guide](getting_started.md)** — In-depth feature walkthrough
- **[API Reference](https://hexdocs.pm/branched_llm)** — Full module documentation
- **[Source Code](https://github.com/dvadell/branched_llm)** — Read the implementation
