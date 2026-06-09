defmodule BranchedLLM.E2E.SchemaTest do
  @moduledoc """
  E2E tests for the schema (structured output) path — validation,
  retries, __structured_output__ tool calls, resolve_provider branches,
  and edge cases.
  """
  use BranchedLLM.E2E.TestCase, async: false

  describe "schema — unified (bypass + live)" do
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
    test "schema path — retries on invalid JSON and succeeds on second attempt", %{
      mode: mode,
      bypass: bypass
    } do
      schema = %{
        "type" => "object",
        "properties" => %{"color" => %{"type" => "string"}},
        "required" => ["color"]
      }

      if mode == :bypass do
        call_count = :counters.new(1, [])

        expect_sse_fn(bypass, fn _conn ->
          :counters.add(call_count, 1, 1)

          case :counters.get(call_count, 1) do
            1 -> sse_content(["not json at all"])
            _ -> sse_schema_content(Jason.encode!(%{"color" => "blue"}))
          end
        end)
      end

      events =
        collect_events(
          default_params(
            message: live_message("What color is the sky?"),
            schema: schema,
            schema_max_retries: 3
          ),
          event_timeout()
        )

      case mode do
        :bypass ->
          assert {:llm_end, "test", result} = find_event(events, :llm_end)
          assert result["color"] == "blue"

        :live ->
          assert find_event(events, :llm_end)
      end
    end

    @tag timeout: 60_000
    test "schema path — retries on valid JSON with wrong schema and succeeds", %{
      mode: mode,
      bypass: bypass
    } do
      schema = %{
        "type" => "object",
        "properties" => %{"count" => %{"type" => "integer"}},
        "required" => ["count"]
      }

      if mode == :bypass do
        call_count = :counters.new(1, [])

        expect_sse_fn(bypass, fn _conn ->
          :counters.add(call_count, 1, 1)

          case :counters.get(call_count, 1) do
            1 -> sse_schema_content(Jason.encode!(%{"count" => "not-a-number"}))
            _ -> sse_schema_content(Jason.encode!(%{"count" => 42}))
          end
        end)
      end

      events =
        collect_events(
          default_params(
            message: live_message("Count something"),
            schema: schema,
            schema_max_retries: 3
          ),
          event_timeout()
        )

      case mode do
        :bypass ->
          assert {:llm_end, "test", result} = find_event(events, :llm_end)
          assert result["count"] == 42

        :live ->
          assert find_event(events, :llm_end)
      end
    end

    @tag timeout: 60_000
    test "schema path — retries on JSON array (non-map) and succeeds", %{
      mode: mode,
      bypass: bypass
    } do
      schema = %{
        "type" => "object",
        "properties" => %{"tag" => %{"type" => "string"}},
        "required" => ["tag"]
      }

      if mode == :bypass do
        call_count = :counters.new(1, [])

        expect_sse_fn(bypass, fn _conn ->
          :counters.add(call_count, 1, 1)

          case :counters.get(call_count, 1) do
            1 -> sse_content([Jason.encode!([1, 2, 3])])
            _ -> sse_schema_content(Jason.encode!(%{"tag" => "hello"}))
          end
        end)
      end

      events =
        collect_events(
          default_params(
            message: live_message("Give me a tag"),
            schema: schema,
            schema_max_retries: 3
          ),
          event_timeout()
        )

      case mode do
        :bypass ->
          assert {:llm_end, "test", result} = find_event(events, :llm_end)
          assert result["tag"] == "hello"

        :live ->
          assert find_event(events, :llm_end)
      end
    end

    @tag timeout: 60_000
    test "schema path — emits llm_error after exhausting all retries on invalid JSON", %{
      mode: mode,
      bypass: bypass
    } do
      schema = %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "string"}},
        "required" => ["value"]
      }

      if mode == :bypass do
        expect_sse(bypass, sse_content(["I am not JSON"]))
      end

      events =
        collect_events(
          default_params(
            message: live_message("Say something non-JSON"),
            schema: schema,
            schema_max_retries: 3
          ),
          event_timeout()
        )

      case mode do
        :bypass ->
          assert find_event(events, :llm_error)
          refute find_event(events, :llm_end)

        :live ->
          assert find_event(events, :llm_end) || find_event(events, :llm_error)
      end
    end
  end

  describe "schema — bypass only" do
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

    @tag :bypass_only
    test "schema path — max retries exhausted returns ValidationError", %{bypass: bypass} do
      schema = %{
        "type" => "object",
        "properties" => %{"key" => %{"type" => "string"}},
        "required" => ["key"]
      }

      call_count = :counters.new(1, [])

      expect_sse_fn(bypass, fn _conn ->
        :counters.add(call_count, 1, 1)
        sse_content(["not valid json"])
      end)

      events =
        collect_events(
          default_params(schema: schema, schema_max_retries: 1),
          event_timeout()
        )

      assert find_event(events, :llm_error)
      refute find_event(events, :llm_end)

      {:llm_error, "test", error} = find_event(events, :llm_error)
      assert is_binary(error) or match?(%BranchedLLM.StructuredOutput.ValidationError{}, error)
    end

    @tag :bypass_only
    test "schema path — tool call in schema mode routes through handle_tool_call_result", %{
      bypass: bypass
    } do
      schema = %{
        "type" => "object",
        "properties" => %{"result" => %{"type" => "string"}},
        "required" => ["result"]
      }

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

      tc = %{
        "id" => "call_1",
        "name" => "calculator",
        "arguments" => Jason.encode!(%{"expression" => "3 * 7"})
      }

      call_count = :counters.new(1, [])

      expect_sse_fn(bypass, fn _conn ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 -> sse_tool_call([tc])
          _ -> sse_schema_content(Jason.encode!(%{"result" => "21"}))
        end
      end)

      events =
        collect_events(
          default_params(
            llm_tools: [calculator],
            schema: schema,
            schema_max_retries: 3
          ),
          event_timeout()
        )

      assert find_event(events, :llm_tool_called)

      assert {:llm_end, "test", result} = find_event(events, :llm_end)
      assert is_map(result)
      assert result["result"] == "21"
    end

    @tag :bypass_only
    test "schema path — __structured_output__ tool call with valid args", %{bypass: bypass} do
      schema = %{
        "type" => "object",
        "properties" => %{"mood" => %{"type" => "string"}},
        "required" => ["mood"]
      }

      dummy_tool =
        ReqLLM.Tool.new!(
          name: "noop",
          description: "No-op",
          parameter_schema: %{type: "object", properties: %{}},
          callback: fn _ -> {:ok, "noop"} end
        )

      tc = %{
        "id" => "call_structured",
        "name" => "__structured_output__",
        "arguments" => Jason.encode!(%{"mood" => "happy"})
      }

      expect_sse(bypass, sse_tool_call([tc]))

      events =
        collect_events(
          default_params(llm_tools: [dummy_tool], schema: schema, schema_max_retries: 0),
          event_timeout()
        )

      assert {:llm_end, "test", result} = find_event(events, :llm_end)
      assert is_map(result)
      assert result["mood"] == "happy"
    end

    @tag :bypass_only
    test "schema path — __structured_output__ tool call with invalid args retries", %{
      bypass: bypass
    } do
      schema = %{
        "type" => "object",
        "properties" => %{"color" => %{"type" => "string"}},
        "required" => ["color"]
      }

      dummy_tool =
        ReqLLM.Tool.new!(
          name: "noop",
          description: "No-op",
          parameter_schema: %{type: "object", properties: %{}},
          callback: fn _ -> {:ok, "noop"} end
        )

      tc_invalid = %{
        "id" => "call_structured_bad",
        "name" => "__structured_output__",
        "arguments" => Jason.encode!(%{"wrong" => "field"})
      }

      call_count = :counters.new(1, [])

      expect_sse_fn(bypass, fn _conn ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 -> sse_tool_call([tc_invalid])
          _ -> sse_schema_content(Jason.encode!(%{"color" => "blue"}))
        end
      end)

      events =
        collect_events(
          default_params(llm_tools: [dummy_tool], schema: schema, schema_max_retries: 3),
          event_timeout()
        )

      assert {:llm_end, "test", result} = find_event(events, :llm_end)
      assert result["color"] == "blue"
    end

    @tag :bypass_only
    test "schema path — __structured_output__ tool call exhausts retries and emits error", %{
      bypass: bypass
    } do
      schema = %{
        "type" => "object",
        "properties" => %{"x" => %{"type" => "integer"}},
        "required" => ["x"]
      }

      dummy_tool =
        ReqLLM.Tool.new!(
          name: "noop",
          description: "No-op",
          parameter_schema: %{type: "object", properties: %{}},
          callback: fn _ -> {:ok, "noop"} end
        )

      tc = %{
        "id" => "call_structured_bad",
        "name" => "__structured_output__",
        "arguments" => Jason.encode!(%{"wrong" => "field"})
      }

      expect_sse(bypass, sse_tool_call([tc]))

      events =
        collect_events(
          default_params(llm_tools: [dummy_tool], schema: schema, schema_max_retries: 0),
          event_timeout()
        )

      assert find_event(events, :llm_error)
      refute find_event(events, :llm_end)
    end

    @tag :bypass_only
    test "schema path — empty text content triggers retry", %{bypass: bypass} do
      schema = %{
        "type" => "object",
        "properties" => %{"word" => %{"type" => "string"}},
        "required" => ["word"]
      }

      call_count = :counters.new(1, [])

      expect_sse_fn(bypass, fn _conn ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          # First call: return empty content
          1 ->
            sse_data(%{
              "id" => "chatcmpl-test",
              "object" => "chat.completion.chunk",
              "created" => 0,
              "model" => "test-model",
              "choices" => [
                %{
                  "index" => 0,
                  "delta" => %{"role" => "assistant", "content" => ""},
                  "finish_reason" => nil
                }
              ]
            }) <>
              sse_data(%{
                "id" => "chatcmpl-test",
                "object" => "chat.completion.chunk",
                "created" => 0,
                "model" => "test-model",
                "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
              }) <>
              sse_data(%{
                "id" => "chatcmpl-test",
                "object" => "chat.completion.chunk",
                "created" => 0,
                "model" => "test-model",
                "choices" => [],
                "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 1, "total_tokens" => 6}
              }) <>
              "data: [DONE]\n\n"

          # Second call: return valid schema response
          _ ->
            sse_schema_content(Jason.encode!(%{"word" => "hello"}))
        end
      end)

      events =
        collect_events(
          default_params(schema: schema, schema_max_retries: 2),
          event_timeout()
        )

      assert {:llm_end, "test", result} = find_event(events, :llm_end)
      assert result["word"] == "hello"
    end

    @tag :bypass_only
    test "schema path with invalid schema — schema_provider_options returns [] gracefully", %{
      bypass: bypass
    } do
      schema = %{"invalid" => "not a valid json schema"}
      expect_sse(bypass, sse_content(["not json"]))

      events =
        collect_events(
          default_params(schema: schema, schema_max_retries: 0),
          event_timeout()
        )

      assert find_event(events, :llm_error) || find_event(events, :llm_end)
    end

    @tag :bypass_only
    test "schema path with Anthropic model — exercises resolve_provider and build_synthetic_tool",
         %{
           bypass: bypass
         } do
      Application.put_env(:branched_llm, :ai_model, "anthropic:claude-3-sonnet")

      schema = %{
        "type" => "object",
        "properties" => %{"mood" => %{"type" => "string"}},
        "required" => ["mood"]
      }

      Bypass.down(bypass)

      events =
        collect_events(
          default_params(schema: schema, schema_max_retries: 0),
          event_timeout()
        )

      assert find_event(events, :llm_error) || find_event(events, :llm_end)
    after
      Application.put_env(:branched_llm, :ai_model, "ollama:test-model")
    end

    @tag :bypass_only
    test "schema path with binary model string — exercises resolve_provider binary clause", %{
      bypass: bypass
    } do
      Application.put_env(:branched_llm, :ai_model, "fakeprovider:some-model")

      schema = %{
        "type" => "object",
        "properties" => %{"x" => %{"type" => "string"}},
        "required" => ["x"]
      }

      Bypass.down(bypass)

      events =
        collect_events(
          default_params(schema: schema, schema_max_retries: 0),
          event_timeout()
        )

      assert find_event(events, :llm_error) || find_event(events, :llm_end)
    after
      Application.put_env(:branched_llm, :ai_model, "ollama:test-model")
    end

    @tag :bypass_only
    test "schema path with no-colon model string — exercises resolve_provider fallback clause", %{
      bypass: bypass
    } do
      Application.put_env(:branched_llm, :ai_model, "nocolonmodel")

      schema = %{
        "type" => "object",
        "properties" => %{"x" => %{"type" => "string"}},
        "required" => ["x"]
      }

      Bypass.down(bypass)

      events =
        collect_events(
          default_params(schema: schema, schema_max_retries: 0),
          event_timeout()
        )

      assert find_event(events, :llm_error) || find_event(events, :llm_end)
    after
      Application.put_env(:branched_llm, :ai_model, "ollama:test-model")
    end

    @tag :bypass_only
    test "schema path — EmptyResult from LLM triggers retry and succeeds", %{bypass: bypass} do
      schema = %{
        "type" => "object",
        "properties" => %{"word" => %{"type" => "string"}},
        "required" => ["word"]
      }

      call_count = :counters.new(1, [])

      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 ->
            # Stream with nil content and no tool calls -> EmptyResult
            empty_stream =
              sse_data(%{
                "id" => "chatcmpl-test",
                "object" => "chat.completion.chunk",
                "created" => 0,
                "model" => "test-model",
                "choices" => [
                  %{
                    "index" => 0,
                    "delta" => %{"role" => "assistant", "content" => nil},
                    "finish_reason" => nil
                  }
                ]
              }) <>
                sse_data(%{
                  "id" => "chatcmpl-test",
                  "object" => "chat.completion.chunk",
                  "created" => 0,
                  "model" => "test-model",
                  "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
                }) <>
                sse_data(%{
                  "id" => "chatcmpl-test",
                  "object" => "chat.completion.chunk",
                  "created" => 0,
                  "model" => "test-model",
                  "choices" => [],
                  "usage" => %{
                    "prompt_tokens" => 5,
                    "completion_tokens" => 0,
                    "total_tokens" => 5
                  }
                }) <>
                "data: [DONE]\n\n"

            conn
            |> Conn.put_resp_header("content-type", "text/event-stream")
            |> Conn.put_resp_header("cache-control", "no-cache")
            |> Conn.send_resp(200, empty_stream)

          _ ->
            valid_json = Jason.encode!(%{"word" => "hello"})

            conn
            |> Conn.put_resp_header("content-type", "text/event-stream")
            |> Conn.put_resp_header("cache-control", "no-cache")
            |> Conn.send_resp(200, sse_schema_content(valid_json))
        end
      end)

      events =
        collect_events(
          default_params(schema: schema, schema_max_retries: 3),
          event_timeout()
        )

      assert {:llm_end, "test", result} = find_event(events, :llm_end)
      assert result["word"] == "hello"
    end
  end
end
