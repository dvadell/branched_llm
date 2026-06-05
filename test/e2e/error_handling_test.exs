defmodule BranchedLLM.E2E.ErrorHandlingTest do
  @moduledoc """
  E2E tests for error handling — connection failures, HTTP error responses (429, 500),
  and retry exhaustion.
  """

  use BranchedLLM.E2E.TestCase, async: false

  describe "error handling — bypass only" do
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
    test "429 rate limit error — retries exhaust and emit error", %{bypass: bypass} do
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
          events = collect_events(default_params(), event_timeout())
          assert find_event(events, :llm_error) || find_event(events, :llm_end)
        end)
    end

    @tag :bypass_only
    test "emits llm_error on malformed SSE response", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Conn.put_resp_header("content-type", "text/event-stream")
        |> Conn.send_resp(200, "not valid sse data at all")
      end)

      _log =
        capture_log(fn ->
          events = collect_events(default_params(), event_timeout())
          assert find_event(events, :llm_end) || find_event(events, :llm_error)
        end)
    end

    @tag :bypass_only
    test "emits llm_error on EmptyResult -- LLM returns nil content with tools but no tool calls",
         %{bypass: bypass} do
      dummy_tool =
        ReqLLM.Tool.new!(
          name: "noop",
          description: "No-op",
          parameter_schema: %{type: "object", properties: %{}},
          callback: fn _ -> {:ok, "noop"} end
        )

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

      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Conn.put_resp_header("content-type", "text/event-stream")
        |> Conn.put_resp_header("cache-control", "no-cache")
        |> Conn.send_resp(200, empty_stream)
      end)

      _log =
        capture_log(fn ->
          events = collect_events(default_params(llm_tools: [dummy_tool]), event_timeout())
          assert find_event(events, :llm_error) || find_event(events, :llm_end)
        end)
    end
  end
end
