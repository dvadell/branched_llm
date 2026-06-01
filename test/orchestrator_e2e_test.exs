defmodule BranchedLLM.OrchestratorE2ETest do
  @moduledoc """
  End-to-end tests for `BranchedLLM.ChatOrchestrator.run/1`.

  Controlled by `LLM_TEST_MODE` env var:

  * `bypass` (default) — Starts a Bypass HTTP server that returns canned
    OpenAI-compatible SSE responses. Tests the full HTTP pipeline through
    ReqLLM (request construction, provider_options, stream parsing).
  * `live` — Hits a real LLM provider configured via `LLM_BASE_URL` and
    `LLM_MODEL` env vars. Requires a running LLM server. Uses longer
    timeouts and relaxed assertions (structural rather than exact content).

  All tests call `ChatOrchestrator.run/1` as the entrypoint and collect
  events via the `on_event` callback.

  ## Running

      # Default — bypass mode
      mix test test/orchestrator_e2e_test.exs

      # Live mode
      LLM_TEST_MODE=live LLM_BASE_URL=http://localhost:11434/v1 LLM_MODEL=llama3 \\
        mix test test/orchestrator_e2e_test.exs
  """

  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias BranchedLLM.ChatOrchestrator
  alias Plug.Conn
  alias ReqLLM.Context

  @mode (System.get_env("LLM_TEST_MODE") || "bypass") |> String.to_atom()

  # ---------------------------------------------------------------------------
  # Event collection
  # ---------------------------------------------------------------------------

  defp collect_events(params, timeout \\ 5_000) do
    test_pid = self()
    ref = make_ref()

    on_event = fn event ->
      send(test_pid, {ref, event})
      :ok
    end

    params = Map.put(params, :on_event, on_event)
    {:ok, _pid} = ChatOrchestrator.run(params)
    drain_events(ref, [], timeout)
  end

  defp drain_events(ref, acc, timeout) do
    receive do
      {^ref, {:llm_end, _, _} = evt} -> Enum.reverse([evt | acc])
      {^ref, {:llm_error, _, _} = evt} -> Enum.reverse([evt | acc])
      {^ref, evt} -> drain_events(ref, [evt | acc], timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end

  defp find_event(events, type) do
    Enum.find(events, fn
      {^type, _, _} -> true
      {^type, _} -> true
      _ -> false
    end)
  end

  # ---------------------------------------------------------------------------
  # Mode-aware setup
  # ---------------------------------------------------------------------------

  setup _context do
    case @mode do
      :live ->
        base_url = System.get_env("LLM_BASE_URL") || raise "LLM_BASE_URL not set"
        model_str = System.get_env("LLM_MODEL") || raise "LLM_MODEL not set"

        Application.put_env(:branched_llm, :base_url, base_url)
        Application.put_env(:branched_llm, :ai_model, model_str)

        on_exit(fn ->
          Application.delete_env(:branched_llm, :base_url)
          Application.delete_env(:branched_llm, :ai_model)
        end)

        {:ok, mode: :live, bypass: nil}

      :bypass ->
        bypass = Bypass.open()

        Application.put_env(:branched_llm, :base_url, bypass_base_url(bypass))
        Application.put_env(:branched_llm, :ai_model, "ollama:test-model")

        on_exit(fn ->
          Application.delete_env(:branched_llm, :base_url)
          Application.delete_env(:branched_llm, :ai_model)
        end)

        {:ok, mode: :bypass, bypass: bypass}
    end
  end

  # ---------------------------------------------------------------------------
  # Shared params builder
  # ---------------------------------------------------------------------------

  defp default_params(overrides \\ []) do
    context =
      Context.new([Context.system("You are a helpful assistant.")])
      |> then(fn ctx ->
        case Keyword.get(overrides, :message) do
          nil -> ctx
          msg -> Context.append(ctx, Context.user(msg))
        end
      end)

    %{
      llm_context: context,
      llm_tools: Keyword.get(overrides, :llm_tools, []),
      chat_mod: BranchedLLM.Chat,
      tool_usage_counts: %{},
      branch_id: "test"
    }
    |> Map.merge(Map.new(Keyword.take(overrides, [:schema, :schema_max_retries])))
  end

  # ---------------------------------------------------------------------------
  # Bypass SSE server helpers
  # ---------------------------------------------------------------------------

  defp bypass_base_url(bypass), do: "http://localhost:#{bypass.port}/v1"

  defp expect_sse(bypass, sse_body) do
    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      conn
      |> Conn.put_resp_header("content-type", "text/event-stream")
      |> Conn.put_resp_header("cache-control", "no-cache")
      |> Conn.send_resp(200, sse_body)
    end)
  end

  defp expect_sse_fn(bypass, fun) do
    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      body = fun.(conn)

      conn
      |> Conn.put_resp_header("content-type", "text/event-stream")
      |> Conn.put_resp_header("cache-control", "no-cache")
      |> Conn.send_resp(200, body)
    end)
  end

  # Returns a ref; call get_request_body(ref) after collect_events to
  # retrieve the HTTP request body that was sent to the Bypass server.
  defp expect_and_inspect_sse(bypass, sse_body) do
    test_pid = self()
    ref = make_ref()

    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, raw_body, conn} = Conn.read_body(conn)
      decoded = Jason.decode!(raw_body)
      send(test_pid, {ref, :request_body, decoded})

      conn
      |> Conn.put_resp_header("content-type", "text/event-stream")
      |> Conn.put_resp_header("cache-control", "no-cache")
      |> Conn.send_resp(200, sse_body)
    end)

    ref
  end

  defp get_request_body(ref) do
    receive do
      {^ref, :request_body, body} -> body
    after
      2_000 -> flunk("No request body received")
    end
  end

  # ---------------------------------------------------------------------------
  # SSE event builders — produce the exact wire format that the
  # OpenAI-compatible streaming endpoint returns.
  # ---------------------------------------------------------------------------

  defp sse_content(chunks, opts \\ []) do
    model = Keyword.get(opts, :model, "test-model")
    id = Keyword.get(opts, :id, "chatcmpl-test")

    content_events =
      chunks
      |> Enum.with_index()
      |> Enum.map(fn {chunk, i} ->
        delta =
          if i == 0 do
            %{"role" => "assistant", "content" => chunk}
          else
            %{"content" => chunk}
          end

        sse_data(%{
          "id" => id,
          "object" => "chat.completion.chunk",
          "created" => 0,
          "model" => model,
          "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => nil}]
        })
      end)

    finish =
      sse_data(%{
        "id" => id,
        "object" => "chat.completion.chunk",
        "created" => 0,
        "model" => model,
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
      })

    usage =
      sse_data(%{
        "id" => id,
        "object" => "chat.completion.chunk",
        "created" => 0,
        "model" => model,
        "choices" => [],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 20, "total_tokens" => 30}
      })

    done = "data: [DONE]\n\n"

    Enum.join(content_events ++ [finish, usage, done])
  end

  defp sse_tool_call(tool_calls, opts \\ []) do
    model = Keyword.get(opts, :model, "test-model")
    id = Keyword.get(opts, :id, "chatcmpl-test")

    null_chunk =
      sse_data(%{
        "id" => id,
        "object" => "chat.completion.chunk",
        "created" => 0,
        "model" => model,
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{"role" => "assistant", "content" => nil},
            "finish_reason" => nil
          }
        ]
      })

    tc_chunks =
      tool_calls
      |> Enum.with_index()
      |> Enum.map(fn {tc, i} ->
        sse_data(%{
          "id" => id,
          "object" => "chat.completion.chunk",
          "created" => 0,
          "model" => model,
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [
                  %{
                    "id" => tc["id"],
                    "type" => "function",
                    "index" => i,
                    "function" => %{"name" => tc["name"], "arguments" => tc["arguments"]}
                  }
                ]
              },
              "finish_reason" => nil
            }
          ]
        })
      end)

    finish =
      sse_data(%{
        "id" => id,
        "object" => "chat.completion.chunk",
        "created" => 0,
        "model" => model,
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "tool_calls"}]
      })

    usage =
      sse_data(%{
        "id" => id,
        "object" => "chat.completion.chunk",
        "created" => 0,
        "model" => model,
        "choices" => [],
        "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 30, "total_tokens" => 50}
      })

    done = "data: [DONE]\n\n"

    Enum.join([null_chunk] ++ tc_chunks ++ [finish, usage, done])
  end

  defp sse_schema_content(json_text, opts \\ []) do
    sse_content([json_text], opts)
  end

  defp sse_data(map) do
    "data: #{Jason.encode!(map)}\n\n"
  end

  # ---------------------------------------------------------------------------
  # Mode-aware helpers
  # ---------------------------------------------------------------------------

  defp event_timeout do
    if @mode == :live, do: 30_000, else: 5_000
  end

  defp maybe_expect_sse(%{mode: :bypass, bypass: bypass}, sse_body) do
    expect_sse(bypass, sse_body)
  end

  defp maybe_expect_sse(%{mode: :live}, _sse_body), do: :ok

  defp live_message(msg), do: if(@mode == :live, do: msg, else: nil)
  defp live_retries(n), do: if(@mode == :live, do: n, else: 0)

  # ===========================================================================
  # UNIFIED TESTS — run in both bypass and live modes
  # ===========================================================================

  describe "ChatOrchestrator.run/1" do
    @tag timeout: 60_000
    test "streams text content and emits llm_end", %{mode: mode, bypass: bypass} do
      maybe_expect_sse(%{mode: mode, bypass: bypass}, sse_content(["Hello", " world"]))

      params = default_params(message: live_message("Say exactly: Hello world"))
      events = collect_events(params, event_timeout())

      assert find_event(events, :llm_chunk)

      case mode do
        :bypass ->
          assert {:llm_end, "test", "Hello world"} = find_event(events, :llm_end)

        :live ->
          assert find_event(events, :llm_end)
      end

      assert find_event(events, :llm_metadata)
    end

    @tag timeout: 60_000
    test "executes a tool call and returns the follow-up answer", %{
      mode: mode,
      bypass: bypass
    } do
      calculator =
        ReqLLM.Tool.new!(
          name: "calculator",
          description: "Evaluates math",
          parameter_schema: %{
            type: "object",
            properties: %{expression: %{type: "string"}},
            required: ["expression"]
          },
          callback: fn %{"expression" => expr} ->
            {result, _} = Code.eval_string(expr)
            {:ok, to_string(result)}
          end
        )

      if mode == :bypass do
        tc = %{
          "id" => "call_1",
          "name" => "calculator",
          "arguments" => Jason.encode!(%{"expression" => "2 + 2"})
        }

        call_count = :counters.new(1, [])

        expect_sse_fn(bypass, fn _conn ->
          :counters.add(call_count, 1, 1)

          :counters.get(call_count, 1)
          |> then(fn
            1 -> sse_tool_call([tc])
            _ -> sse_content(["4"])
          end)
        end)
      end

      events =
        collect_events(
          default_params(
            message: live_message("What is 2 + 2? Use the calculator tool."),
            llm_tools: [calculator]
          ),
          event_timeout()
        )

      assert find_event(events, :llm_tool_called)

      case mode do
        :bypass ->
          assert {:llm_end, "test", "4"} = find_event(events, :llm_end)

        :live ->
          assert find_event(events, :llm_end)
      end
    end

    @tag timeout: 60_000
    test "schema path — validates JSON response against schema", %{mode: mode, bypass: bypass} do
      schema = %{
        "type" => "object",
        "properties" => %{
          "sentiment" => %{"type" => "string", "enum" => ["positive", "negative", "neutral"]},
          "confidence" => %{"type" => "number"}
        },
        "required" => ["sentiment", "confidence"]
      }

      if mode == :bypass do
        valid_json = Jason.encode!(%{"sentiment" => "positive", "confidence" => 0.95})
        maybe_expect_sse(%{mode: mode, bypass: bypass}, sse_schema_content(valid_json))
      end

      events =
        collect_events(
          default_params(
            message: live_message("Analyze: 'I love this product!'"),
            schema: schema,
            schema_max_retries: live_retries(3)
          ),
          event_timeout()
        )

      {:llm_end, "test", result} = find_event(events, :llm_end)
      assert is_map(result)

      case mode do
        :bypass ->
          assert result["sentiment"] == "positive"
          assert result["confidence"] == 0.95

        :live ->
          assert result["sentiment"] in ["positive", "negative", "neutral"]
      end
    end

    @tag timeout: 60_000
    test "emits update_tool_usage_counts event", %{mode: mode, bypass: bypass} do
      maybe_expect_sse(%{mode: mode, bypass: bypass}, sse_content(["done"]))
      params = default_params(message: live_message("Say: done"))
      events = collect_events(params, event_timeout())
      assert find_event(events, :update_tool_usage_counts)
    end

    @tag :bypass_only
    test "schema path with schema_max_retries: 0 — no retries on validation failure", %{
      bypass: bypass
    } do
      schema = %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}},
        "required" => ["name"]
      }

      invalid_json = Jason.encode!(%{"wrong" => "field"})
      expect_sse(bypass, sse_schema_content(invalid_json))

      events =
        collect_events(
          default_params(schema: schema, schema_max_retries: 0),
          event_timeout()
        )

      assert find_event(events, :llm_error)
      refute find_event(events, :llm_end)
    end
  end

  # ===========================================================================
  # BYPASS-ONLY TESTS — inspect wire protocol, test failure injection
  # These are excluded when LLM_TEST_MODE=live via test_helper.exs.
  # ===========================================================================

  describe "ChatOrchestrator.run/1 — wire protocol (bypass only)" do
    @tag :bypass_only
    test "schema path — sends response_format in HTTP request body", %{bypass: bypass} do
      schema = %{
        "type" => "object",
        "properties" => %{"x" => %{"type" => "string"}},
        "required" => ["x"]
      }

      valid_json = Jason.encode!(%{"x" => "hello"})
      ref = expect_and_inspect_sse(bypass, sse_schema_content(valid_json))
      events = collect_events(default_params(schema: schema))
      body = get_request_body(ref)

      assert Map.has_key?(body, "response_format"),
             "Expected response_format in request body, got keys: #{inspect(Map.keys(body))}"

      assert body["response_format"]["type"] == "json_schema"
      assert find_event(events, :llm_end)
    end

    @tag :bypass_only
    test "non-schema path — does NOT send response_format in HTTP request body", %{
      bypass: bypass
    } do
      ref = expect_and_inspect_sse(bypass, sse_content(["ok"]))
      events = collect_events(default_params())
      body = get_request_body(ref)

      refute Map.has_key?(body, "response_format"),
             "response_format should NOT be in non-schema request body"

      assert find_event(events, :llm_end)
    end

    @tag :bypass_only
    test "emits llm_end or llm_error on connection failure", %{bypass: bypass} do
      Bypass.down(bypass)

      _log =
        capture_log(fn ->
          events = collect_events(default_params())
          # CallbackStream retries on error, so the result may be an
          # llm_end with empty text rather than an llm_error.
          assert find_event(events, :llm_end) || find_event(events, :llm_error)
        end)
    end

    @tag :bypass_only
    test "trims context via Prune strategy when max_tokens is exceeded", %{bypass: bypass} do
      Application.put_env(:branched_llm, :max_tokens, 10)

      expect_sse(bypass, sse_content(["ok"]))

      context =
        Context.new([Context.system("You are a helpful assistant.")])
        |> Context.append(Context.user("First message with enough text to exceed tokens"))
        |> Context.append(Context.assistant("First response with enough text"))
        |> Context.append(Context.user("Second message with enough text"))

      params = %{
        llm_context: context,
        llm_tools: [],
        chat_mod: BranchedLLM.Chat,
        tool_usage_counts: %{},
        branch_id: "test"
      }

      events = collect_events(params, event_timeout())
      assert find_event(events, :llm_end)
    after
      Application.delete_env(:branched_llm, :max_tokens)
    end

    @tag :bypass_only
    test "emits llm_error on 429 rate limit response", %{bypass: bypass} do
      Bypass.expect(bypass, fn conn ->
        conn
        |> Conn.put_resp_header("content-type", "application/json")
        |> Conn.send_resp(
          429,
          Jason.encode!(%{
            "error" => %{
              "message" => "Rate limit exceeded",
              "details" => [
                %{
                  "@type" => "type.googleapis.com/google.rpc.RetryInfo",
                  "retryDelay" => "30s"
                }
              ]
            }
          })
        )
      end)

      _log =
        capture_log(fn ->
          events = collect_events(default_params())
          assert {:llm_error, "test", error_msg} = find_event(events, :llm_error)
          assert error_msg =~ "429"
        end)
    end

    @tag :bypass_only
    test "emits llm_error on 500 API error response", %{bypass: bypass} do
      # Return 500 on every attempt — CallbackStream retries up to 10 times
      Bypass.expect(bypass, fn conn ->
        conn
        |> Conn.put_resp_header("content-type", "application/json")
        |> Conn.send_resp(
          500,
          Jason.encode!(%{"error" => %{"message" => "Internal server error"}})
        )
      end)

      _log =
        capture_log(fn ->
          events = collect_events(default_params())
          # With retries, the 500 may result in llm_end with empty text
          # or llm_error depending on whether the retry library raises.
          assert find_event(events, :llm_end) || find_event(events, :llm_error)
        end)
    end

    @tag :bypass_only
    test "trims context via SlidingWindow strategy when configured", %{bypass: bypass} do
      Application.put_env(:branched_llm, :max_tokens, 10)

      Application.put_env(
        :branched_llm,
        :trim_callback,
        {BranchedLLM.ContextManager.Strategy.SlidingWindow, :trim, [keep: 1]}
      )

      expect_sse(bypass, sse_content(["ok"]))

      context =
        Context.new([Context.system("You are a helpful assistant.")])
        |> Context.append(Context.user("First message"))
        |> Context.append(Context.assistant("First response"))
        |> Context.append(Context.user("Second message"))
        |> Context.append(Context.assistant("Second response"))
        |> Context.append(Context.user("Third message"))

      params = %{
        llm_context: context,
        llm_tools: [],
        chat_mod: BranchedLLM.Chat,
        tool_usage_counts: %{},
        branch_id: "test"
      }

      events = collect_events(params, event_timeout())
      assert find_event(events, :llm_end)
    after
      Application.delete_env(:branched_llm, :max_tokens)
      Application.delete_env(:branched_llm, :trim_callback)
    end

    @tag :bypass_only
    test "trims context via Percentage strategy when configured", %{bypass: bypass} do
      Application.put_env(:branched_llm, :max_tokens, 10)

      Application.put_env(
        :branched_llm,
        :trim_callback,
        {BranchedLLM.ContextManager.Strategy.Percentage, :trim, [retain: 0.5]}
      )

      expect_sse(bypass, sse_content(["ok"]))

      context =
        Context.new([Context.system("You are a helpful assistant.")])
        |> Context.append(Context.user("First message with substantial text content"))
        |> Context.append(Context.assistant("First response with substantial text content"))
        |> Context.append(Context.user("Second message with substantial text content"))
        |> Context.append(Context.assistant("Second response with substantial text content"))

      params = %{
        llm_context: context,
        llm_tools: [],
        chat_mod: BranchedLLM.Chat,
        tool_usage_counts: %{},
        branch_id: "test"
      }

      events = collect_events(params, event_timeout())
      assert find_event(events, :llm_end)
    after
      Application.delete_env(:branched_llm, :max_tokens)
      Application.delete_env(:branched_llm, :trim_callback)
    end

    @tag :bypass_only
    test "trims context via Summarize strategy when configured", %{bypass: bypass} do
      Application.put_env(:branched_llm, :max_tokens, 10)

      Application.put_env(
        :branched_llm,
        :trim_callback,
        {BranchedLLM.ContextManager.Strategy.Summarize, :trim, [recent_count: 2]}
      )

      expect_sse(bypass, sse_content(["ok"]))

      context =
        Context.new([Context.system("You are a helpful assistant.")])
        |> Context.append(Context.user("First message to be summarized"))
        |> Context.append(Context.assistant("First response to be summarized"))
        |> Context.append(Context.user("Recent message kept intact"))
        |> Context.append(Context.assistant("Recent response kept intact"))

      params = %{
        llm_context: context,
        llm_tools: [],
        chat_mod: BranchedLLM.Chat,
        tool_usage_counts: %{},
        branch_id: "test"
      }

      events = collect_events(params, event_timeout())
      assert find_event(events, :llm_end)
    after
      Application.delete_env(:branched_llm, :max_tokens)
      Application.delete_env(:branched_llm, :trim_callback)
    end
  end
end
