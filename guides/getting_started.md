# Getting Started

This guide walks you through using BranchedLLM to build LLM-powered applications with branching conversations, tool execution, and streaming responses.

## Prerequisites

- Elixir ~> 1.15
- An LLM API endpoint (OpenAI-compatible, Ollama, etc.)
- Basic familiarity with Elixir

---

## Step 1: Installation

Add BranchedLLM to your `mix.exs`:

```elixir
def deps do
  [
    {:branched_llm, "~> 0.1.0"},
    {:req_llm, "~> 1.0.0"},
    {:ecto, "~> 3.13"}
  ]
end
```

Configure your LLM provider in `config/config.exs`:

```elixir
config :branched_llm,
  ai_model: "openai:cara-cpu",
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

For real-time UI updates, use `send_message_stream/3`:

```elixir
{:ok, stream_response, context_builder, tool_calls} =
  Chat.send_message_stream("Tell me a story", context)

# Consume the stream token by token
stream_response
|> ReqLLM.StreamResponse.tokens()
|> Enum.each(fn chunk ->
  IO.write(chunk.text)
end)

IO.puts("")

# Build the final context with the assistant's complete response
final_text = Enum.map_join(ReqLLM.StreamResponse.tokens(stream_response), & &1.text)
new_context = context_builder.(final_text)
```

The `context_builder` function takes the final assistant text and returns an updated `ReqLLM.Context` with the user message and assistant response appended.

---

## Step 3: Branching Conversations

One of BranchedLLM's standout features is the ability to fork conversations at any point.

### Creating a BranchedChat

```elixir
alias BranchedLLM.{BranchedChat, Message}

# Start with some initial messages
messages = [
  Message.new(:system, "You are a helpful assistant."),
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
calculator_tool = ReqLLM.Tool.new(
  name: "calculator",
  description: "Evaluates a mathematical expression and returns the result",
  parameters: %{
    type: "object",
    properties: %{
      expression: %{
        type: "string",
        description: "The mathematical expression to evaluate, e.g. '2 + 2'"
      }
    },
    required: ["expression"]
  },
  execute: fn %{"expression" => expr} ->
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

{:ok, stream_response, context_builder, tool_calls} =
  Chat.send_message_stream("What is 847 * 392?", context, tools: [calculator_tool])

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

params = %{
  message: "What is Elixir?",
  llm_context: context,
  caller_pid: self(),
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

def handle_info({:llm_end, branch_id, context_builder}, socket) do
  # Stream complete — build final context
  new_context = context_builder.(get_last_assistant_text(socket))
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
  # Start the orchestrator for the next message
  ChatOrchestrator.run(%{params | message: next_message})
end
```

---

## Step 6: Custom Chat Behaviour

To use a different LLM provider (Anthropic, Google, etc.), implement `BranchedLLM.ChatBehaviour`:

```elixir
defmodule MyApp.GoogleChat do
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
    # Call Google API, return ReqLLM.StreamResponse
    # Adapt the response to ReqLLM's format
    {:ok, stream_response, context_builder, []}
  end

  @impl true
  def send_message(message, context, opts) do
    {:ok, text, new_context} = send_message_stream(message, context, opts)
    # Consume stream and return
    {:ok, text, new_context}
  end

  @impl true
  def execute_tool(tool, args) do
    tool.execute.(args)
  end

  @impl true
  def health_check do
    # Ping the API
    :ok
  end
end
```

Then use it:

```elixir
branched_chat = BranchedChat.new(MyApp.GoogleChat, messages, context)
```

---

## Step 7: Error Handling

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
- **[Source Code](https://github.com/your-org/branched_llm)** — Read the implementation
