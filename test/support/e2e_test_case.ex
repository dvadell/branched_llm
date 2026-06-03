defmodule BranchedLLM.E2E.TestCase do
  import ExUnit.Callbacks, only: [on_exit: 1]
  import ExUnit.Assertions, only: [flunk: 1]

  alias BranchedLLM.E2E.TestCase
  alias Plug.Conn
  alias ReqLLM.Context

  @moduledoc """
  Shared test infrastructure for E2E tests.

  Provides the mode-aware setup, event collection helpers, SSE builders,
  bypass server helpers, and default params builder used by all E2E test files.

  ## Usage

      defmodule BranchedLLM.E2E.StreamingTest do
        use BranchedLLM.E2E.TestCase, async: false

        describe "streaming" do
          test "streams text content", %{mode: mode, bypass: bypass} do
            ...
          end
        end
      end

  ## Running

      # Default — bypass mode
      mix test test/e2e/

      # Live mode
      LLM_TEST_MODE=live LLM_BASE_URL=http://localhost:11434/v1 LLM_MODEL=llama3 \\
        mix test test/e2e/
  """

  defmacro __using__(opts) do
    quote do
      use ExUnit.Case, unquote(opts)
      import ExUnit.CaptureLog
      import BranchedLLM.E2E.TestCase

      alias BranchedLLM.ChatOrchestrator
      alias BranchedLLM.ContextManager.Strategy.SlidingWindow
      alias Plug.Conn
      alias ReqLLM.Context

      @mode (System.get_env("LLM_TEST_MODE") || "bypass") |> String.to_atom()

      setup _context do
        TestCase.__setup__(@mode)
      end
    end
  end

  def __setup__(mode) do
    case mode do
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
  # Event collection
  # ---------------------------------------------------------------------------

  def collect_events(params, timeout \\ 5_000) do
    test_pid = self()
    ref = make_ref()

    on_event = fn event ->
      send(test_pid, {ref, event})
      :ok
    end

    params = Map.put(params, :on_event, on_event)
    {:ok, _pid} = BranchedLLM.ChatOrchestrator.run(params)
    drain_events(ref, [], timeout)
  end

  def drain_events(ref, acc, timeout) do
    receive do
      {^ref, {:llm_end, _, _} = evt} -> Enum.reverse([evt | acc])
      {^ref, {:llm_error, _, _} = evt} -> Enum.reverse([evt | acc])
      {^ref, evt} -> drain_events(ref, [evt | acc], timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end

  def find_event(events, type) do
    Enum.find(events, fn
      {^type, _, _} -> true
      {^type, _} -> true
      _ -> false
    end)
  end

  # ---------------------------------------------------------------------------
  # Shared params builder
  # ---------------------------------------------------------------------------

  def default_params(overrides \\ []) do
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

  def bypass_base_url(bypass), do: "http://localhost:#{bypass.port}/v1"

  def expect_sse(bypass, sse_body) do
    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      conn
      |> Conn.put_resp_header("content-type", "text/event-stream")
      |> Conn.put_resp_header("cache-control", "no-cache")
      |> Conn.send_resp(200, sse_body)
    end)
  end

  def expect_sse_fn(bypass, fun) do
    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      body = fun.(conn)

      conn
      |> Conn.put_resp_header("content-type", "text/event-stream")
      |> Conn.put_resp_header("cache-control", "no-cache")
      |> Conn.send_resp(200, body)
    end)
  end

  def expect_and_inspect_sse(bypass, sse_body) do
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

  def get_request_body(ref) do
    receive do
      {^ref, :request_body, body} -> body
    after
      2_000 -> flunk("No request body received")
    end
  end

  # ---------------------------------------------------------------------------
  # SSE event builders
  # ---------------------------------------------------------------------------

  def sse_content(chunks, opts \\ []) do
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

  def sse_tool_call(tool_calls, opts \\ []) do
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

  def sse_schema_content(json_text, opts \\ []) do
    sse_content([json_text], opts)
  end

  def sse_data(map) do
    "data: #{Jason.encode!(map)}\n\n"
  end

  # ---------------------------------------------------------------------------
  # Mode-aware helpers
  # ---------------------------------------------------------------------------

  def event_timeout do
    mode = (System.get_env("LLM_TEST_MODE") || "bypass") |> String.to_atom()
    if mode == :live, do: 30_000, else: 5_000
  end

  def maybe_expect_sse(%{mode: :bypass, bypass: bypass}, sse_body) do
    expect_sse(bypass, sse_body)
  end

  def maybe_expect_sse(%{mode: :live}, _sse_body), do: :ok

  def live_message(msg) do
    mode = (System.get_env("LLM_TEST_MODE") || "bypass") |> String.to_atom()
    if mode == :live, do: msg, else: nil
  end

  def live_retries(n) do
    mode = (System.get_env("LLM_TEST_MODE") || "bypass") |> String.to_atom()
    if mode == :live, do: n, else: 0
  end
end
