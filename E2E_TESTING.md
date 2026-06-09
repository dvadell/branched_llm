# E2E Testing

End-to-end tests exercise `BranchedLLM.ChatOrchestrator.run/1` as the main
entrypoint, driving the full HTTP pipeline through ReqLLM — request
construction, provider options, SSE stream parsing, and event emission.

All e2e tests live under `test/e2e`.

## Two modes, one test suite

The `LLM_TEST_MODE` environment variable selects the backend:

| Mode       | `LLM_TEST_MODE` | What happens                                              |
|------------|------------------|----------------------------------------------------------|
| **bypass** | _(unset or `bypass`)_ | Starts a Bypass HTTP server returning canned SSE responses. Assertions are exact (`"Hello world"`). |
| **live**   | `live`           | Hits a real LLM provider. Assertions are structural (`find_event(events, :llm_end)` rather than exact text). |

`test/test_helper.exs` reads `LLM_TEST_MODE` and sets `ExUnit.start(exclude: …)` accordingly:

- **bypass** mode → excludes `:live` tag (no live tests exist anymore, but the tag is reserved)
- **live** mode → excludes `:bypass_only` tag

## Running

```bash
# Bypass mode (default) — no LLM server needed
mix test test/e2e

# Live mode — requires a running LLM server
LLM_TEST_MODE=live \
LLM_BASE_URL=http://localhost:11434/v1 \
LLM_MODEL=ollama:cara-cpu \
mix test test/e2e
```

Live mode also accepts `--trace` for per-test output (tests are slow, 2–3 s each).

## How it works

### Mode selection at compile time

The test module reads the env var once at compilation:

```elixir
@mode (System.get_env("LLM_TEST_MODE") || "bypass") |> String.to_atom()
```

### Setup branches on mode

A single `setup/1` callback inspects `@mode`:

- **`:live`** — reads `LLM_BASE_URL` and `LLM_MODEL`, sets application env, returns `{:ok, mode: :live, bypass: nil}`.
- **`:bypass`** — starts `Bypass.open()`, sets `:base_url` to the Bypass port, returns `{:ok, mode: :bypass, bypass: bypass}`.

### Event collection

Every test calls `collect_events/2`, which:

1. Creates an `on_event` callback that sends events to the test process.
2. Calls `ChatOrchestrator.run/1`.
3. Drains events via `receive` until `:llm_end` / `:llm_error` or a timeout.

```elixir
events = collect_events(params, event_timeout())
```

`event_timeout/0` returns 30 000 ms in live mode, 5 000 ms in bypass mode.

### Mode-aware helpers

| Helper | Purpose |
|--------|---------|
| `maybe_expect_sse(%{mode, bypass}, body)` | Sets a Bypass expectation in bypass mode; no-op in live mode. |
| `live_message(msg)` | Returns `msg` in live mode, `nil` in bypass mode (so `default_params` skips appending a user message). |
| `live_retries(n)` | Returns `n` in live mode (allowing retries for non-deterministic LLMs), `0` in bypass mode. |

### Assertions

Bypass mode asserts **exact** values (the canned response is deterministic):

```elixir
assert {:llm_end, "test", "Hello world"} = find_event(events, :llm_end)
```

Live mode asserts **structural** presence (the LLM's exact wording varies):

```elixir
case mode do
  :bypass -> assert {:llm_end, "test", "Hello world"} = find_event(events, :llm_end)
  :live   -> assert find_event(events, :llm_end)
end
```

For schema tests in live mode, assert the **shape** of the result rather than exact values:

```elixir
case mode do
  :bypass -> assert result["sentiment"] == "positive"
  :live   -> assert result["sentiment"] in ["positive", "negative", "neutral"]
end
```

## Unified tests vs bypass-only tests

### Unified tests (`describe "ChatOrchestrator.run/1"`)

Run in **both** modes. They use the mode-aware helpers so the same test body
works with either backend.

### Bypass-only tests (`describe "… — wire protocol (bypass only)"`)

Tagged `@tag :bypass_only`. Excluded when `LLM_TEST_MODE=live`.

These tests inspect the **wire protocol** (e.g., checking that `response_format`
appears in the HTTP request body) or inject **failure scenarios** (e.g.,
`Bypass.down/1` to simulate connection failure). They cannot be expressed in
live mode because we cannot control the real LLM's responses or the network
path between the test and the provider.

## Adding a new e2e test

### 1. Decide: unified or bypass-only?

| Question | Yes → | No → |
|----------|-------|------|
| Does this test make sense against a real LLM? | Unified | Bypass-only |
| Does it depend on a specific response body (exact text, specific JSON)? | Bypass-only | Unified |
| Does it inspect the HTTP request (headers, body fields)? | Bypass-only | Unified |
| Does it inject failures (connection drop, malformed SSE)? | Bypass-only | Unified |

### 2. Add a unified test

Place it in the `"ChatOrchestrator.run/1"` describe block:

```elixir
@tag timeout: 60_000
test "your new scenario", %{mode: mode, bypass: bypass} do
  # 1. Set up Bypass expectations (no-op in live mode)
  maybe_expect_sse(%{mode: mode, bypass: bypass}, sse_content(["your response"]))

  # 2. Build params — include a user message for live mode
  params = default_params(message: live_message("Your prompt to the LLM"))

  # 3. Collect events
  events = collect_events(params, event_timeout())

  # 4. Assert — branch on mode for exact vs structural checks
  assert find_event(events, :llm_chunk)

  case mode do
    :bypass -> assert {:llm_end, "test", "your response"} = find_event(events, :llm_end)
    :live   -> assert find_event(events, :llm_end)
  end
end
```

Key points:

- Always include `@tag timeout: 60_000` (live LLM calls are slow).
- Use `live_message/1` for prompts — returns `nil` in bypass mode so no user
  message is appended to the context (the Bypass server doesn't care about
  the prompt content).
- Use `live_retries/1` for `schema_max_retries` — real LLMs may need retries.
- Branch assertions on `mode` for exact vs structural matching.

### 3. Add a bypass-only test

Place it in the `"… — wire protocol (bypass only)"` describe block and tag it:

```elixir
@tag :bypass_only
test "your wire-protocol check", %{bypass: bypass} do
  # Use expect_sse, expect_sse_fn, or expect_and_inspect_sse directly
  expect_sse(bypass, sse_content(["ok"]))

  events = collect_events(default_params())

  assert find_event(events, :llm_end)
end
```

### 4. Bypass SSE helpers

| Helper | Use when |
|--------|----------|
| `expect_sse(bypass, body)` | Return a fixed SSE response. |
| `expect_sse_fn(bypass, fun)` | Return a dynamic SSE response (e.g., different response on each call for tool-call loops). |
| `expect_and_inspect_sse(bypass, body)` | Capture the HTTP request body for assertion (e.g., check `response_format`). Use `get_request_body(ref)` to retrieve it. |

### 5. SSE event builders

| Builder | Produces |
|---------|----------|
| `sse_content(["chunk1", "chunk2"])` | OpenAI-compatible text SSE stream. |
| `sse_tool_call([%{"id" => …, "name" => …, "arguments" => …}])` | Tool-call SSE stream. |
| `sse_schema_content(json_string)` | Schema (JSON) response — wraps `sse_content/1`. |

All accept `opts` for `:model` and `:id` (default: `"test-model"`, `"chatcmpl-test"`).

## Environment variables

| Variable | Required | Description |
|----------|----------|-------------|
| `LLM_TEST_MODE` | No | `bypass` (default) or `live`. |
| `LLM_BASE_URL` | Live only | Base URL of the LLM provider (e.g., `http://localhost:11434/v1`). |
| `LLM_MODEL` | Live only | Model identifier as `provider:model` (e.g., `ollama:cara-cpu`). |
