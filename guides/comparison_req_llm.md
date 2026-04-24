# Comparison: BranchedLLM vs. ReqLLM

If you are wondering whether to use `BranchedLLM` or just stick with `ReqLLM` directly, this guide explains the architectural differences and the "value-add" of the BranchedLLM wrapper.

---

## The Core Philosophy

*   **ReqLLM** is a **Low-Level HTTP Client**. It focuses on the "plumbing": making requests to LLM APIs, handling Server-Sent Events (SSE) for streaming, and providing a clean way to define tools. It is stateless.
*   **BranchedLLM** is a **High-Level Conversation Framework**. It focuses on the "user experience": managing the state of complex conversations, handling background tasks, and providing a protocol for UI integration (like LiveView).

---

## Feature Comparison

| Feature | ReqLLM | BranchedLLM |
| :--- | :--- | :--- |
| **HTTP/Streaming** | ✅ Primary Focus | ✅ Inherited from ReqLLM |
| **Tool Definition** | ✅ Native (`ReqLLM.Tool`) | ✅ Native (`ReqLLM.Tool`) |
| **Branching** | ❌ No | ✅ **First-class feature** |
| **Async Orchestration**| ❌ Manual | ✅ **Automatic (`ChatOrchestrator`)** |
| **Tool Loop** | ❌ Manual (One-off) | ✅ **Recursive (Auto-execute & loop)** |
| **Message IDs** | ❌ No (List-based) | ✅ **Immutable IDs for UI tracking** |
| **Error Handling** | ❌ Raw API Errors | ✅ **Human-friendly formatting** |
| **Caching** | ❌ No | ✅ **Tool result caching** |

---

## Why use BranchedLLM?

### 1. Conversation Branching
In `ReqLLM`, a conversation is a flat list of maps. If you want to "go back" and try a different question, you have to manually slice the list.
`BranchedLLM` uses a tree structure. You can `branch_off/2` at any message ID. This is essential for AI playgrounds, writing assistants, or any UI where the user might want to explore different "what-if" scenarios.

### 2. The Orchestration Loop
When an LLM calls a tool, the process is:
1. LLM returns a tool call.
2. You execute the code.
3. You append the result to the context.
4. You call the LLM **again**.
5. If the LLM calls *another* tool, repeat.

`ReqLLM` gives you the tools to do step 2, but you have to write the recursive loop yourself. `BranchedLLM.ChatOrchestrator` handles this entire lifecycle in a background Task, sending status updates (e.g., `{:llm_status, _, "Using calculator..."}`) to your UI automatically.

### 3. UI-Ready Message Protocol
`ReqLLM` chunks are raw text fragments. `BranchedLLM` transforms these into a message protocol that fits perfectly into a Phoenix LiveView or a React frontend. It manages:
*   **Chunk accumulation**: Building the full assistant message as it streams.
*   **Busy states**: Knowing if the AI is currently thinking on a specific branch.
*   **Message Queuing**: If a user sends a message while the AI is busy, BranchedLLM can enqueue it.

### 4. Robust Message Identity
`ReqLLM` uses simple lists: `[%{role: "user", content: "..."}]`.
`BranchedLLM` uses the `Message` struct. Every message has a unique UUID and metadata. This makes it significantly easier to implement features like:
*   "Delete this specific message"
*   "Edit this message and re-run from here"
*   "Highlight the tool calls associated with this response"

---

## When to use ReqLLM directly?

You might prefer to use `ReqLLM` without the `BranchedLLM` wrapper if:
*   You are building a **one-shot CLI** or a simple background script that doesn't need conversation history.
*   You have a **stateless API** where you receive the full history from the client every time and just return a single string.
*   You want **total control** over the HTTP request and don't want any abstraction between you and the LLM endpoint.

## Module Comparison

| ReqLLM Primitive | BranchedLLM Module | Role of BranchedLLM |
| :--- | :--- | :--- |
| `ReqLLM.Context` | `BranchedLLM.Message` | Adds immutable IDs and structured metadata to individual messages. |
| `ReqLLM.Context` | `BranchedLLM.BranchedChat` | Wraps the list of messages into a tree structure with branch IDs and parent links. |
| `ReqLLM.stream_text/3` | `BranchedLLM.Chat` | Wraps the API call to provide behavior implementation and defaults. |
| `ReqLLM.StreamResponse`| `BranchedLLM.ChatOrchestrator`| Manages the lifecycle of the stream response, handling tools and retries. |
| `ReqLLM.Tool.execute/2` | `BranchedLLM.ToolHandler` | Orchestrates the execution of *multiple* tool calls and context injection. |
| N/A | `BranchedLLM.ToolCache` | Adds an Ecto-backed persistence layer for tool results (missing in ReqLLM). |
| N/A | `BranchedLLM.LLMErrorFormatter`| Translates raw HTTP/API errors into user-friendly strings. |

## Conclusion

`BranchedLLM` isn't just a wrapper; it's a **state engine**. It takes the excellent foundations of `ReqLLM` and adds the machinery needed to build "Chat-GPT-like" interfaces where branching, background orchestration, and resilient error handling are required.
