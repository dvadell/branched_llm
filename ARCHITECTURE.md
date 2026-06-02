# Architecture

BranchedLLM is an Elixir library for orchestrating LLM conversations with streaming, tool calls, and structured output — backed by [ReqLLM](https://github.com/anthropics/req_llm) as the default provider.

## Entry Point

Everything starts at **`ChatOrchestrator.run/1`**.

```elixir
{:ok, task_pid} = BranchedLLM.ChatOrchestrator.run(params)
```

It spawns an async `Task` that runs the full request/response cycle: LLM call → stream classification → tool execution → recursive re-call → final response. The caller receives events through an `on_event` callback.

There are two convenience wrappers that delegate to `run/1`:

| Wrapper | Module | Sync? | Notes |
|---------|--------|-------|-------|
| `BranchedLLM.send_message/5` | `BranchedLLM` | No | Reads context from a `BranchedChat` struct, appends the user message, calls `ChatOrchestrator.run/1` |
| `Chat.send_message/3` | `BranchedLLM.Chat` | Yes | Blocks until `:llm_end` or `:llm_error` (60 s timeout) |

---

## Visual Summary

```
ChatOrchestrator.run(params) ─── Task.start ─── retry (10×, 100 ms)
│
└─► process_llm_request(params) ◄──── RECURSIVE ENTRY
    │
    ├─► Chat.send_message_stream/2
    │   ├─ ContextManager.trim (if over max_tokens)
    │   └─ call_llm
    │       ├─ Enforcer.prepare_request (if schema → inject provider_options)
    │       ├─ Enforcer.build_synthetic_tool (if Anthropic + schema)
    │       └─ ReqLLM.stream_text(model, messages, opts) ──► HTTP
    │           │
    │           └─► {:ok, StreamResponse}
    │               │
    │               └─► stream_result
    │                   ├─ no tools → %ContentResult{stream: response}
    │                   └─ tools → handle_stream_for_tools
    │                       └─► StreamResponse.classify  ◄── consumes full stream
    │                           ├─ :tool_calls   → %ToolCallResult{tool_calls, context, metadata_handle}
    │                           ├─ :final_answer → %ContentResult{stream: materialized_chunks}
    │                           ├─ (empty)       → %EmptyResult{}
    │                           └─ (encode err)  → %ErrorResult{reason}
    │
    │   call_llm wraps: {:ok, stream_result(...} | {:error, reason}
    │
    ├─ ContentResult ──► process_stream
    │   │  StreamResponse.tokens → Enum.reduce_while
    │   │    │  per token: emit :llm_chunk, accumulate full_text
    │   │    └─► {sent_any_chunks?, full_text}
    │   │  emit :llm_metadata (via MetadataHandle.await)
    │   │  if schema → handle_schema_validation
    │   │  else
    │   │    emit :llm_end with full_text
    │   │    return :ok ──── TERMINAL
    │   │
    │   └─ schema validation failed → retry_with_schema_validation
    │      (up to schema_max_retries, default 2)
    │      ├─ success → emit :llm_end with validated_map ──── TERMINAL
    │      └─ exhausted → emit :llm_error with ValidationError
    │
    ├─ ToolCallResult (regular tools)
    │   │  emit :llm_metadata (via MetadataHandle.await)
    │   │  emit :llm_tool_called per tool call
    │   │  emit :llm_status "Using <tool_names>..."
    │   │  ToolHandler: find → execute → append tool_result to context
    │   └─ recurse: process_llm_request(updated_params)
    │
    ├─ ToolCallResult (structured-output synthetic tool)
    │   │  emit :llm_metadata
    │   │  validate args against schema
    │   ├─ valid → emit :llm_end with args ──── TERMINAL
    │   └─ invalid → retry_with_schema_validation
    │
    └─ EmptyResult / {:error, _} → return {:error, ...} ──► outer retry
```

---

## Message Protocol

The orchestrator communicates exclusively through the `on_event` callback. Events are tuples:

| Event | When | Third element |
|-------|------|---------------|
| `{:llm_chunk, branch_id, chunk}` | Per streaming token | Text chunk (string) |
| `{:llm_end, branch_id, payload}` | Final response | `full_text` (string) or `validated_map` (when `schema:` is provided) |
| `{:llm_tool_called, branch_id, tool_call}` | LLM requests a tool | Map with `:id`, `:name`, `:arguments` |
| `{:llm_status, branch_id, status}` | Status update | String, e.g. `"Thinking..."`, `"Using calculator..."` |
| `{:llm_metadata, branch_id, metadata}` | Token usage etc. | Map from `ReqLLM.StreamResponse.MetadataHandle` |
| `{:llm_error, branch_id, error}` | Unrecoverable error | String or `%ValidationError{}` |
| `{:update_tool_usage_counts, counts}` | After each LLM call | Map of `%{tool_name_atom => count}` |

No ordering guarantee between `:llm_metadata` and other events; it is emitted as soon as the metadata handle resolves.

---

## Module Map

### Orchestration layer

| Module | File | Role |
|--------|------|------|
| `ChatOrchestrator` | `lib/branched_llm/chat_orchestrator.ex` | Main entry point. Spawns a `Task`, retries on error, drives the recursive LLM→tool→LLM loop. |
| `Chat` | `lib/branched_llm/chat.ex` | Default `ChatBehaviour` implementation. Wraps `ReqLLM.stream_text/3`, classifies streams into `StreamResult` variants, manages context trimming and API keys. |
| `ChatBehaviour` | `lib/branched_llm/chat_behaviour.ex` | Behaviour contract — `send_message_stream/2`, `execute_tool/2`, `default_model/0`, etc. Swap backends by implementing this. |

### Result types

| Module | File | Role |
|--------|------|------|
| `StreamResult` | `lib/branched_llm/llm/stream_result.ex` | Tagged-union container. Four variants: `ContentResult`, `ToolCallResult`, `EmptyResult`, `ErrorResult`. The orchestrator pattern-matches on the struct type to decide the next step. |

### Context management

| Module | File | Role |
|--------|------|------|
| `ContextManager` | `lib/branched_llm/context_manager.ex` | Trims context to fit within token limits before each LLM call. Delegates to a pluggable strategy. |
| `Strategy` | `lib/branched_llm/context_manager/strategy.ex` | Behaviour for trimming strategies. |
| `Strategy.Percentage` | `lib/branched_llm/context_manager/strategy/percentage.ex` | Keep the last X% of tokens (default strategy). |
| `Strategy.Prune` | `lib/branched_llm/context_manager/strategy/prune.ex` | Drop oldest non-system messages until context fits. |
| `Strategy.SlidingWindow` | `lib/branched_llm/context_manager/strategy/sliding_window.ex` | Keep only the last N messages. |
| `Strategy.Summarize` | `lib/branched_llm/context_manager/strategy/summarize.ex` | Condense older messages into a summary (stub). |

### Tool execution

| Module | File | Role |
|--------|------|------|
| `ToolHandler` | `lib/branched_llm/tool_handler.ex` | Finds the matching `ReqLLM.Tool` from the tool list, calls its callback, appends the tool result to the context. |
| `ToolCache` | `lib/branched_llm/tool_cache.ex` | Proxy module — delegates to the configured `ToolCacheBehaviour` implementation. |
| `ToolCacheBehaviour` | `lib/branched_llm/tool_cache_behaviour.ex` | Behaviour: `get_result/2`, `save_result/3`. |
| `ToolCache.InMemory` | `lib/branched_llm/tool_cache/in_memory.ex` | Default cache (no-op). |
| `ToolCache.Ecto` | `lib/branched_llm/tool_cache/ecto.ex` | Database-backed cache via Ecto. |

### Structured output

| Module | File | Role |
|--------|------|------|
| `Enforcer` | `lib/branched_llm/structured_output/enforcer.ex` | Behaviour + dispatcher. Routes to a provider-specific enforcer based on the model's provider atom. |
| `Enforcer.JsonSchema` | `lib/branched_llm/structured_output/enforcer/json_schema.ex` | OpenAI — sets `response_format: json_schema` in `provider_options`. |
| `Enforcer.ToolCoerce` | `lib/branched_llm/structured_output/enforcer/tool_coerce.ex` | Anthropic — injects a synthetic `__structured_output__` tool; the orchestrator short-circuits it. |
| `Enforcer.Grammar` | `lib/branched_llm/structured_output/enforcer/grammar.ex` | Ollama/llama.cpp — passes the schema as `format` (grammar-constrained decoding). |
| `Enforcer.Prompt` | `lib/branched_llm/structured_output/enforcer/prompt.ex` | Fallback — appends the schema to the system prompt. No token-level guarantee. |
| `Validator` | `lib/branched_llm/structured_output/validator.ex` | Parses raw LLM text as JSON, validates against a JSON Schema (`ex_json_schema`). |
| `ValidationError` | `lib/branched_llm/structured_output/validation_error.ex` | Error struct for exhausted schema retries. |

### Conversation tree

| Module | File | Role |
|--------|------|------|
| `BranchedChat` | `lib/branched_llm/branched_chat.ex` | Pure state container for a tree-like conversation with branches. Stores messages as `BranchedLLM.Message` structs, tracks active branch, pending message queue, and task PIDs. Does **not** call the orchestrator — the caller composes them. |
| `Message` | `lib/branched_llm/message.ex` | Immutable message struct with `id`, `role`, `content`, `metadata`, `deleted` flag. Decoupled from `ReqLLM.Message`. |

### Utilities

| Module | File | Role |
|--------|------|------|
| `UUID` | `lib/branched_llm/uuid.ex` | Internal UUID generation (Uniq → Ecto → crypto fallback). |

---

## Configuration

All config lives under `:branched_llm` — environment-variable-driven, single source of truth:

```elixir
# config/config.exs
config :branched_llm,
  ai_model: System.get_env("LLM_MODEL") || "ollama:cara-cpu",
  base_url: System.get_env("LLM_BASE_URL") || "http://host.docker.internal:11434"
```

`Chat.default_model/0` reads `:ai_model`, resolves `"provider:model_id"` strings into `%LLMDB.Model{}` structs via `ReqLLM.model/1`. `Chat.stream_text/3` passes `base_url` and `api_key` from `endpoints/0` directly to `ReqLLM.stream_text/3` as options, so `ReqLLM` never needs its own config block.

---

## Two Retry Loops

The system has two independent retry mechanisms:

| | Outer retry | Schema retry |
|---|---|---|
| **Where** | `ChatOrchestrator.run/1` | `retry_with_schema_validation/5` |
| **Trigger** | `process_llm_request` returns `{:error, _}` | `Validator.validate/2` or `Validator.check_schema/2` fails |
| **Max attempts** | 10 (100 ms apart) | `schema_max_retries + 1` (default 3) |
| **Context** | Original — same `llm_call_params` | Modified — appends the failed response + retry prompt |
| **On exhaustion** | Emits `:llm_error` | Emits `:llm_error` with `%ValidationError{}` |

---

## Data Flow: `call_llm` → `StreamResult`

```
Chat.send_message_stream(context, opts)
  └─► call_llm(model, context, tools, opts)
       └─► ReqLLM.stream_text(model, messages, opts) ──► {:ok, StreamResponse}
            └─► stream_result(stream_response, tools)
                 │
                 ├─ no tools  → %ContentResult{stream: stream_response}
                 │
                 └─ tools present → handle_stream_for_tools
                      └─► StreamResponse.classify(stream_response)
                           ├─ :tool_calls   → %ToolCallResult{tool_calls, context, metadata_handle}
                           ├─ :final_answer → %ContentResult{stream: materialized_stream}
                           ├─ (empty)       → %EmptyResult{}
                           └─ (encode error)→ %ErrorResult{reason}
```

`call_llm` wraps the bare struct: `{:ok, stream_result(...)}` or `{:error, reason}`. The orchestrator pattern-matches on the struct type inside the `{:ok, ...}` tuple.

---

## Tool Call Cycle

```
LLM returns :tool_calls
  │
  ├─ emit {:llm_tool_called, branch_id, %{id, name, arguments}}   (per tool)
  ├─ emit {:llm_status, branch_id, "Using calculator..."}
  │
  ├─ For each tool call (limit: 10 calls per tool per turn):
  │   ├─ Find matching ReqLLM.Tool by name
  │   ├─ Execute tool callback
  │   ├─ Append Context.tool_result(tool_call_id, result)
  │   └─ Update tool_usage_counts
  │
  └─ recurse: process_llm_request(updated_params)
      └─ LLM sees conversation + tool results, responds
```

Tool results that exceed the per-tool limit (10) get a `"Tool limit reached"` message instead of execution, prompting the LLM to summarize.

---

## Structured Output Flow

When `schema:` is present in `params`:

**1. Request preparation** (`build_stream_opts/1` + `call_llm/4`)
- `Enforcer.resolve_provider(model)` → `:openai` | `:anthropic` | `:ollama` | fallback
- `Enforcer.prepare_request(provider, %{}, schema)` → injects `provider_options` (e.g. `response_format: json_schema`)
- For Anthropic: `Enforcer.build_synthetic_tool(schema)` appends a `__structured_output__` tool

**2. Response validation** (two paths)

| Path | Trigger | Validation |
|------|---------|------------|
| Text response | `ContentResult` | `Validator.validate(full_text, schema)` — parses JSON, then checks schema |
| Synthetic tool | `ToolCallResult` with `__structured_output__` | `Validator.check_schema(args, schema)` — args already parsed |

**3. Retry on failure**
- Builds a retry prompt: *"Your previous response was invalid… Validation errors: …"*
- Appends assistant (failed JSON) + user (retry prompt) to context
- Makes a new LLM call
- Repeats up to `schema_max_retries` times (default 2)
- On exhaustion: emits `:llm_error` with `%ValidationError{message: "Schema validation failed after N attempts"}`
