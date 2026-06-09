# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.2.0 — 2026-05-22

### Breaking Changes — Application-Owned Context

This release removes the `context_builder` closure and shifts context ownership to the application. The library is now a stateless function: **context in, tokens out**. This eliminates hidden state and makes the event protocol simpler to understand.

#### What changed and how to upgrade

**1. `Chat.send_message_stream/3` → `Chat.send_message_stream/2`**

The `message` argument has been removed. The application must now add the user message to the context before calling.

```elixir
# Before (0.1.x)
{:ok, result} = Chat.send_message_stream("What is 2+2?", context, tools: tools)

# After (0.2.0)
context_with_msg = ReqLLM.Context.append(context, ReqLLM.Context.user("What is 2+2?"))
{:ok, result} = Chat.send_message_stream(context_with_msg, tools: tools)
```

**2. `:llm_end` event payload: `context_builder` → `full_text`**

The `:llm_end` event now carries the full accumulated text of the assistant's response as a string, instead of a closure.

```elixir
# Before (0.1.x)
def handle_info({:llm_end, _branch_id, context_builder}, socket) do
  new_context = context_builder.(accumulated_text)
  {:noreply, assign(socket, :context, new_context)}
end

# After (0.2.0)
def handle_info({:llm_end, _branch_id, full_text}, socket) do
  new_context = ReqLLM.Context.append(socket.assigns.context, ReqLLM.Context.assistant(full_text))
  {:noreply, assign(socket, :context, new_context)}
end
```

**3. `StreamResult` structs no longer have a `context_builder` field**

All four `StreamResult` variants (`ContentResult`, `ToolCallResult`, `EmptyResult`, `ErrorResult`) have had their `context_builder` field removed.

```elixir
# Before (0.1.x)
%ContentResult{stream: stream, context_builder: builder}
new_context = builder.(full_text)

# After (0.2.0)
%ContentResult{stream: stream}
# The application appends the assistant message itself:
new_context = ReqLLM.Context.append(context, ReqLLM.Context.assistant(full_text))
```

**4. `ChatOrchestrator.llm_call_params` no longer has a `message` key**

The orchestrator params map no longer accepts `message:`. The user message must be pre-appended to `llm_context` before calling `ChatOrchestrator.run/1`.

```elixir
# Before (0.1.x)
params = %{
  message: "What is 2+2?",
  llm_context: context,
  on_event: on_event,
  llm_tools: tools,
  chat_mod: Chat,
  tool_usage_counts: %{},
  branch_id: "main"
}

# After (0.2.0)
llm_context = ReqLLM.Context.append(context, ReqLLM.Context.user("What is 2+2?"))
params = %{
  llm_context: llm_context,
  on_event: on_event,
  llm_tools: tools,
  chat_mod: Chat,
  tool_usage_counts: %{},
  branch_id: "main"
}
```

**5. `BranchedChat.finish_ai_response/3` accepts `full_text` instead of a closure**

The third argument is now the assistant's full text string (from the `:llm_end` event) instead of a `context_builder` function.

```elixir
# Before (0.1.x)
chat = BranchedChat.finish_ai_response(chat, "main", context_builder)

# After (0.2.0)
chat = BranchedChat.finish_ai_response(chat, "main", full_text)
```

**6. `ChatBehaviour` callback signature changed**

If you implement `ChatBehaviour` yourself, update the callback:

```elixir
# Before (0.1.x)
@callback send_message_stream(String.t(), Context.t(), keyword()) ::
  {:ok, StreamResult.t()} | {:error, term()}

# After (0.2.0)
@callback send_message_stream(Context.t(), keyword()) ::
  {:ok, StreamResult.t()} | {:error, term()}
```

### Unchanged APIs

- **`Chat.send_message/3`** — The synchronous convenience API is unchanged. It still accepts a `message` string and manages context internally.
- **`BranchedLLM.send_message/5`** — The top-level convenience is unchanged. It still accepts a `message` string and appends it to the context before calling the orchestrator.

### Removed

- `context_builder` field from `ContentResult`, `ToolCallResult`, `EmptyResult`, and `ErrorResult` structs
- `@type context_builder` type alias from `StreamResult` module
- `Chat.inject_context_builder/2` private function
- `Chat.unwrap_call_llm_result/2` private function
- `BranchedChat.get_last_assistant_message_content/1` private function
- `message` key from `ChatOrchestrator.llm_call_params` type

### Fixed

- `Chat.call_llm/3` now correctly unwraps `stream_result/2`'s `{:ok, _}` tuple before returning, preventing a double-wrapped `{:ok, {:ok, result}}` that caused the orchestrator to crash with a `CaseClauseError`.
