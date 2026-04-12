# Interactive IEx Tutorial

This tutorial walks you through every major feature of BranchedLLM using the Elixir interactive shell. You can copy-paste each block directly into `iex -S mix`.

## Setup

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

Message.deleted?(user)
#=> false

# Convert to/from legacy map format
map = Message.to_map(user)
#=> %{sender: :user, content: "Hello, how are you?", id: "...", deleted: false}

restored = Message.from_map(map)
#=> %BranchedLLM.Message{role: :user, content: "Hello, how are you?", ...}
```

---

## Part 2: Basic Chat with BranchedChat

`BranchedChat` manages a tree of conversation branches. Let's start simple — a single "main" branch.

```elixir
alias BranchedLLM.{BranchedChat, Message, Chat}

# Create initial messages
messages = [
  Message.new(:system, "You are a helpful assistant."),
  Message.new(:user, "What is 2 + 2?"),
  Message.new(:assistant, "2 + 2 equals 4.")
]

# Create a context
context = Chat.new_context("You are a helpful assistant.")

# Create the branched chat
chat = BranchedChat.new(Chat, messages, context)

# Inspect the structure
chat.branch_ids
#=> ["main"]

chat.current_branch_id
#=> "main"

# Get messages from the current branch
BranchedChat.get_current_messages(chat)
#=> [
#     %Message{role: :system, ...},
#     %Message{role: :user, content: "What is 2 + 2?"},
#     %Message{role: :assistant, content: "2 + 2 equals 4."}
#   ]

# Get the LLM context from the current branch
BranchedChat.get_current_context(chat)
#=> %ReqLLM.Context{messages: [...]}
```

### Adding Messages

```elixir
# Add a user message to the current branch
chat = BranchedChat.add_user_message(chat, "What about 3 * 7?")

# Check the messages
messages = BranchedChat.get_current_messages(chat)
List.last(messages)
#=> %Message{role: :user, content: "What about 3 * 7?", ...}

# The branch name is auto-generated from the first user message
chat.branches["main"].name
#=> "What about 3 * 7?"  (or the first user message, truncated to 30 chars)
```

### Simulating AI Responses

```elixir
# Simulate appending an AI response chunk by chunk
chat = BranchedChat.append_chunk(chat, "main", "3 * 7")
chat = BranchedChat.append_chunk(chat, "main", " equals ")
chat = BranchedChat.append_chunk(chat, "main", "21.")

# Check the result
messages = BranchedChat.get_current_messages(chat)
List.last(messages)
#=> %Message{role: :assistant, content: "3 * 7 equals 21.", ...}
```

In a real app, chunks come from the LLM stream and are sent to your UI via `ChatOrchestrator`.

---

## Part 3: Branching Conversations

This is where BranchedLLM shines. You can fork any conversation at any message.

```elixir
# Let's see the current messages
messages = BranchedChat.get_current_messages(chat)
#=> [
#     %Message{role: :system, content: "You are a helpful assistant.", id: "sys-1"},
#     %Message{role: :user, content: "What is 2 + 2?", id: "user-1"},
#     %Message{role: :assistant, content: "2 + 2 equals 4.", id: "asst-1"},
#     %Message{role: :user, content: "What about 3 * 7?", id: "user-2"},
#     %Message{role: :assistant, content: "3 * 7 equals 21.", id: "asst-2"}
#   ]

# Branch off from the first user question ("What is 2 + 2?")
branch_point_id = Enum.at(messages, 1).id

chat = BranchedChat.branch_off(chat, branch_point_id)

# We're now on a new branch!
chat.current_branch_id
#=> "some-uuid-..."

chat.branch_ids
#=> ["main", "some-uuid-..."]

# The new branch only has messages up to the branch point
new_branch_messages = BranchedChat.get_current_messages(chat)
#=> [
#     %Message{role: :system, ...},
#     %Message{role: :user, content: "What is 2 + 2?"}
#   ]

# Add a DIFFERENT follow-up on this new branch
chat = BranchedChat.add_user_message(chat, "Can you explain the history of math?")

# Now switch back to main
chat = BranchedChat.switch_branch(chat, "main")

BranchedChat.get_current_messages(chat) |> List.last()
#=> %Message{role: :assistant, content: "3 * 7 equals 21.", ...}
```

### Branch Tree

```elixir
# View the full tree
tree = BranchedChat.build_tree(chat)
#=> [
#     %{
#       id: "main",
#       children: [
#         %{id: "some-uuid-...", children: []}
#       ]
#     }
#   ]

# Create a child branch from the new branch
chat = BranchedChat.switch_branch(chat, Enum.at(chat.branch_ids, 1))
chat = BranchedChat.add_user_message(chat, "What is math?")
math_msg = List.last(BranchedChat.get_current_messages(chat))

chat = BranchedChat.branch_off(chat, math_msg.id)
chat = BranchedChat.add_user_message(chat, "Tell me about geometry")

# Now the tree has depth
chat = BranchedChat.switch_branch(chat, "main")
BranchedChat.build_tree(chat)
#=> [
#     %{
#       id: "main",
#       children: [
#         %{
#           id: "branch-1",
#           children: [
#             %{id: "branch-2", children: []}
#           ]
#         }
#       ]
#     }
#   ]
```

### Deleting Messages

```elixir
chat = BranchedChat.switch_branch(chat, "main")
messages = BranchedChat.get_current_messages(chat)
# Find the "3 * 7" user message
msg_to_delete = Enum.find(messages, fn m -> m.content =~ "3 * 7" end)

# Soft-delete it
chat = BranchedChat.delete_message(chat, msg_to_delete.id)

# The message is still in the list but marked as deleted
deleted_msg = Enum.find(BranchedChat.get_current_messages(chat), &(&1.id == msg_to_delete.id))
Message.deleted?(deleted_msg)
#=> true

# The LLM context is rebuilt without the deleted message
ctx = BranchedChat.get_current_context(chat)
ctx.messages
#=> The context no longer includes the deleted message's content
```

---

## Part 4: Message Queue and Busy State

BranchedChat tracks whether a branch is actively processing an LLM response and queues additional messages.

```elixir
alias BranchedLLM.{BranchedChat, Message}

# Setup
messages = [Message.new(:system, "You are helpful.")]
context = BranchedLLM.Chat.new_context("You are helpful.")
chat = BranchedChat.new(BranchedLLM.Chat, messages, context)

# Initially, the branch is not busy
BranchedChat.busy?(chat, "main")
#=> false

# Simulate setting an active task (e.g., an LLM Task PID)
chat = BranchedChat.set_active_task(chat, "main", self(), "Hello")

BranchedChat.busy?(chat, "main")
#=> true

# While busy, you can enqueue messages
chat = BranchedChat.enqueue_message(chat, "main", "Are you there?")
chat = BranchedChat.enqueue_message(chat, "main", "Follow-up question")

chat.branches["main"].pending_messages
#=> ["Are you there?", "Follow-up question"]

# Dequeue messages one at a time
{next, chat} = BranchedChat.dequeue_message(chat, "main")
#=> {"Are you there?", %BranchedChat{...}}

{next, chat} = BranchedChat.dequeue_message(chat, "main")
#=> {"Follow-up question?", %BranchedChat{...}}

{next, chat} = BranchedChat.dequeue_message(chat, "main")
#=> {nil, %BranchedChat{...}}

# Clear the active task
chat = BranchedChat.clear_active_task(chat, "main")
BranchedChat.busy?(chat, "main")
#=> false
```

### Tool Status

```elixir
chat = BranchedChat.set_tool_status(chat, "main", "Using calculator...")
chat.branches["main"].tool_status
#=> "Using calculator..."

# Status is cleared when a chunk is appended
chat = BranchedChat.append_chunk(chat, "main", "The answer is 42.")
chat.branches["main"].tool_status
#=> nil
```

---

## Part 5: Tools

Tools allow the LLM to call your code. Let's create a calculator tool and see the full pipeline in action.

### Defining a Tool

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

calculator.name
#=> "calculator"
```

### ToolHandler — Pure Function Processing

`ToolHandler` processes tool calls deterministically. Let's simulate what happens when the LLM returns a tool call.

```elixir
alias BranchedLLM.ToolHandler

# Simulate a tool call from the LLM
tool_call = ReqLLM.ToolCall.new(
  "call_abc123",
  "calculator",
  %{"expression" => "100 / 5"}
)

# Create a context with the assistant's tool call
context = ReqLLM.Context.new([
  ReqLLM.Context.system("You are helpful."),
  ReqLLM.Context.user("What is 100 / 5?"),
  ReqLLM.Context.assistant("", tool_calls: [tool_call])
])

# Process the tool call
new_context = ToolHandler.handle_tool_calls(
  [tool_call],
  context,
  [calculator],
  BranchedLLM.Chat
)

# The result is appended to the context
List.last(new_context.messages)
#=> %{role: :tool, tool_call_id: "call_abc123", content: "20.0"}
```

### Tool Cache

```elixir
alias BranchedLLM.ToolCache

# Save a result
ToolCache.save_result("calculator", %{"expression" => "2+2"}, "4")
#=> :ok

# Retrieve it
ToolCache.get_result("calculator", %{"expression" => "2+2"})
#=> {:ok, "4"}

# Different args = cache miss
ToolCache.get_result("calculator", %{"expression" => "3+3"})
#=> :error
```

---

## Part 6: ChatOrchestrator

The `ChatOrchestrator` runs the LLM request in a separate `Task` and communicates with your process via messages. This is the module you'd use in a LiveView.

### Setup

First, let's define a mock chat module that simulates LLM responses without a real API:

```elixir
defmodule MockChat do
  @behaviour BranchedLLM.ChatBehaviour

  @impl true
  def new_context(system_prompt) do
    ReqLLM.Context.new([ReqLLM.Context.system(system_prompt)])
  end

  @impl true
  def reset_context(context) do
    system_msgs = Enum.filter(context.messages, &(&1.role == :system))
    ReqLLM.Context.new(system_msgs)
  end

  @impl true
  def send_message_stream(message, context, opts) do
    # Simulate a streaming response
    stream = Stream.map(["Hello", ", ", "world", "!"], fn text ->
      %ReqLLM.StreamChunk{type: :content, text: text}
    end)

    context_builder = fn final_text ->
      ReqLLM.Context.append(context, ReqLLM.Context.assistant(final_text))
    end

    metadata_task = Task.async(fn -> %{model: "mock"} end)

    stream_response = %ReqLLM.StreamResponse{
      stream: stream,
      context: context,
      model: "mock",
      cancel: fn -> :ok end,
      metadata_task: metadata_task
    }

    {:ok, stream_response, context_builder, []}
  end

  @impl true
  def send_message(message, context, opts) do
    {:ok, "Hello, world!", ReqLLM.Context.append(context, ReqLLM.Context.assistant("Hello, world!"))}
  end

  @impl true
  def execute_tool(tool, args) do
    tool.execute.(args)
  end

  @impl true
  def health_check do
    :ok
  end
end
```

### Running the Orchestrator

```elixir
alias BranchedLLM.ChatOrchestrator

context = MockChat.new_context("You are helpful.")

params = %{
  message: "Hello!",
  llm_context: context,
  caller_pid: self(),
  llm_tools: [],
  chat_mod: MockChat,
  tool_usage_counts: %{},
  branch_id: "main"
}

{:ok, _task_pid} = ChatOrchestrator.run(params)

# Now receive the messages:
receive do
  {:llm_chunk, "main", chunk} ->
    IO.write(chunk)
    # Prints: Hello, world!
    :got_chunks

  {:llm_end, "main", _context_builder} ->
    :stream_complete
end

receive do
  {:update_tool_usage_counts, counts} ->
    {:got_counts, counts}
end
```

### With Tool Calls

```elixir
# Define a module that simulates a tool call response
defmodule MockToolChat do
  @behaviour BranchedLLM.ChatBehaviour

  @impl true
  def new_context(system_prompt), do: ReqLLM.Context.new([ReqLLM.Context.system(system_prompt)])
  @impl true
  def reset_context(ctx), do: ReqLLM.Context.new(Enum.filter(ctx.messages, &(&1.role == :system)))

  @impl true
  def send_message_stream(message, context, opts) do
    tools = Keyword.get(opts, :tools, [])

    # Simulate: first call returns a tool call, second call returns text
    if message == "" do
      # Second call — LLM produces final answer
      stream = Stream.map(["The answer is 2500"], fn text ->
        %ReqLLM.StreamChunk{type: :content, text: text}
      end)

      context_builder = fn final_text ->
        ReqLLM.Context.append(context, ReqLLM.Context.assistant(final_text))
      end

      {:ok, %ReqLLM.StreamResponse{
        stream: stream, context: context, model: "mock",
        cancel: fn -> :ok end, metadata_task: Task.async(fn -> %{} end)
      }, context_builder, []}
    else
      # First call — LLM wants to use a tool
      tool_call = ReqLLM.ToolCall.new("call_1", "calculator", %{"expression" => "50 * 50"})

      stream = Stream.map([], & &1)

      context_builder = fn _ -> context end

      {:ok, %ReqLLM.StreamResponse{
        stream: stream, context: context, model: "mock",
        cancel: fn -> :ok end, metadata_task: Task.async(fn -> %{} end)
      }, context_builder, [tool_call]}
    end
  end

  @impl true
  def send_message(msg, ctx, opts), do: {:ok, "done", ctx}

  @impl true
  def execute_tool(tool, args) do
    calculator = ReqLLM.Tool.new(
      name: "calculator",
      description: "Evaluate math",
      parameters: %{expression: "string"},
      execute: fn %{"expression" => e} ->
        {r, _} = Code.eval_string(e)
        {:ok, to_string(r)}
      end
    )
    calculator.execute.(args)
  end

  @impl true
  def health_check, do: :ok
end

# Run it
context = MockToolChat.new_context("You are helpful.")

params = %{
  message: "What is 50 * 50?",
  llm_context: context,
  caller_pid: self(),
  llm_tools: [
    ReqLLM.Tool.new(
      name: "calculator",
      description: "Evaluate math",
      parameters: %{expression: "string"},
      execute: fn %{"expression" => e} ->
        {r, _} = Code.eval_string(e)
        {:ok, to_string(r)}
      end
    )
  ],
  chat_mod: MockToolChat,
  tool_usage_counts: %{"calculator" => 0},
  branch_id: "main"
}

{:ok, _pid} = ChatOrchestrator.run(params)

# Receive messages:
# 1. {:llm_status, "main", "Using calculator..."}
# 2. {:update_tool_usage_counts, %{"calculator" => 1}}
# 3. {:llm_chunk, "main", "The"} ...
# 4. {:llm_end, "main", context_builder}
```

### Error Handling

```elixir
defmodule ErrorChat do
  @behaviour BranchedLLM.ChatBehaviour

  @impl true
  def new_context(system_prompt), do: ReqLLM.Context.new([ReqLLM.Context.system(system_prompt)])
  @impl true
  def reset_context(ctx), do: ctx
  @impl true
  def send_message_stream(_msg, _ctx, _opts), do: {:error, "Service unavailable"}
  @impl true
  def send_message(_msg, _ctx, _opts), do: {:error, "Service unavailable"}
  @impl true
  def execute_tool(_tool, _args), do: {:error, "Tool failed"}
  @impl true
  def health_check, do: {:error, :unavailable}
end

params = %{
  message: "Hello",
  llm_context: ErrorChat.new_context("test"),
  caller_pid: self(),
  llm_tools: [],
  chat_mod: ErrorChat,
  tool_usage_counts: %{},
  branch_id: "main"
}

{:ok, _pid} = ChatOrchestrator.run(params)

receive do
  {:llm_error, "main", error_msg} ->
    IO.puts("Error: #{error_msg}")
    #=> "Error: Error: \"Service unavailable\""
end
```

---

## Part 7: StreamParser

The `StreamParser` module provides pure functions for analyzing LLM response streams.

```elixir
alias BranchedLLM.LLM.StreamParser

# Simulate a content stream
content_stream = Stream.map(
  ["Hello", ", ", "world"],
  fn text -> %ReqLLM.StreamChunk{type: :content, text: text} end
)

# Detect intent
{intent, consumed, remaining} = StreamParser.consume_until_intent(content_stream)
#=> {:content, [%StreamChunk{...}, ...], #Stream<...>}

# Consume to text
text = StreamParser.consume_to_text(content_stream)
#=> "Hello, world"

# Accumulate text from chunks
chunk = %ReqLLM.StreamChunk{type: :content, text: "Hello"}
acc = StreamParser.accumulate_text(chunk, "")
#=> "Hello"

chunk2 = %ReqLLM.StreamChunk{type: :content, text: " world"}
acc = StreamParser.accumulate_text(chunk2, acc)
#=> "Hello world"
```

---

## Part 8: LLMErrorFormatter

```elixir
alias BranchedLLM.LLMErrorFormatter

# Rate limit error
rate_error = %ReqLLM.Error.API.Request{
  status: 429,
  reason: "Too many requests",
  response_body: %{
    "details" => [
      %{
        "@type" => "type.googleapis.com/google.rpc.RetryInfo",
        "retryDelay" => "30s"
      }
    ]
  }
}

LLMErrorFormatter.format(rate_error)
#=> "The AI is busy. Wait a moment and try again later. Please retry in 30s."

# Without retry delay
no_delay_error = %ReqLLM.Error.API.Request{
  status: 429,
  reason: "Too many requests",
  response_body: %{"details" => []}
}

LLMErrorFormatter.format(no_delay_error)
#=> "The AI is busy. Wait a moment and try again later."

# Generic API error
other_error = %ReqLLM.Error.API.Request{status: 500, reason: "Internal error"}
LLMErrorFormatter.format(other_error)
#=> "API error (status 500). Please try again."
```

---

## Part 9: Putting It All Together — A Complete Mini-App

Here's a simple REPL-style chat that demonstrates the full BranchedLLM workflow:

```elixir
defmodule MiniChat do
  alias BranchedLLM.{BranchedChat, Message, ChatOrchestrator, Chat}

  def start do
    context = Chat.new_context("You are a concise assistant.")
    chat = BranchedChat.new(Chat, [Message.new(:system, "You are a concise assistant.")], context)

    IO.puts("🤖 BranchedLLM Mini Chat")
    IO.puts("Type a message, or 'quit' to exit.")
    IO.puts("Type 'branch' to branch off the last message.")
    IO.puts("")

    chat_loop(chat)
  end

  defp chat_loop(chat) do
    input = IO.gets("You> ") |> String.trim()

    cond do
      input in ["quit", "exit", "q"] ->
        IO.puts("👋 Goodbye!")
        :ok

      input == "branch" ->
        messages = BranchedChat.get_current_messages(chat)
        last_user = Enum.find(messages, fn m -> m.role == :user end)

        if last_user do
          chat = BranchedChat.branch_off(chat, last_user.id)
          IO.puts("🌿 Branched! Now on a new branch.")
          chat_loop(chat)
        else
          IO.puts("No user message to branch from.")
          chat_loop(chat)
        end

      input == "" ->
        chat_loop(chat)

      true ->
        if BranchedChat.busy?(chat, chat.current_branch_id) do
          IO.puts("⏳ Busy — message queued.")
          chat = BranchedChat.enqueue_message(chat, chat.current_branch_id, input)
          chat_loop(chat)
        else
          chat = BranchedChat.add_user_message(chat, input)

          # In a real app, you'd start the ChatOrchestrator here.
          # For this demo, we'll use Chat.send_message directly.
          context = BranchedChat.get_current_context(chat)

          case Chat.send_message(input, context, model: BranchedLLM.Chat.default_model()) do
            {:ok, response, new_context} ->
              IO.puts("🤖 #{response}")
              chat = %{chat | branches: Map.update!(chat.branches, chat.current_branch_id, fn b ->
                %{b | context: new_context, messages: b.messages ++ [Message.new(:assistant, response)]}
              end)}
              chat_loop(chat)

            {:error, reason} ->
              IO.puts("❌ #{reason}")
              chat = BranchedChat.add_error_message(chat, chat.current_branch_id, "Error: #{reason}")
              chat_loop(chat)
          end
        end
    end
  end
end

# Run it:
# MiniChat.start()
```

---

## Summary

| Concept | Module | Key Functions |
|---|---|---|
| Messages | `BranchedLLM.Message` | `new/3`, `mark_deleted/1`, `deleted?/1` |
| Branching | `BranchedLLM.BranchedChat` | `new/3`, `branch_off/2`, `switch_branch/2`, `delete_message/2` |
| Chat | `BranchedLLM.Chat` | `send_message/3`, `send_message_stream/3`, `new_context/1` |
| Tools | `BranchedLLM.ToolHandler` | `handle_tool_calls/4` |
| Orchestration | `BranchedLLM.ChatOrchestrator` | `run/1` |
| Streaming | `BranchedLLM.LLM.StreamParser` | `consume_until_intent/1`, `consume_to_text/1` |
| Errors | `BranchedLLM.LLMErrorFormatter` | `format/1` |
| Caching | `BranchedLLM.ToolCache` | `get_result/2`, `save_result/3` |

---

## Next Steps

- **[Getting Started Guide](getting_started.md)** — In-depth feature walkthrough
- **[API Reference](https://hexdocs.pm/branched_llm)** — Full module documentation
- **[Source Code](https://github.com/your-org/branched_llm)** — Read the implementation
