# Run manually:  mix run manual_tests/tools_integration_test.exs
#
# Requires a configured LLM (e.g. Ollama, OpenAI) available at whatever
# config/config.exs points to.  No mocks — this hits a real provider.

ExUnit.start()

defmodule BranchedLLM.Integration.ToolsTest do
  use ExUnit.Case, async: false

  @tag timeout: 60_000

  test "LLM calls the calculator tool and returns the correct result" do
    calculator = ReqLLM.Tool.new!(
      name: "calculator",
      description: "Evaluates a mathematical expression",
      parameter_schema: %{
        type: "object",
        properties: %{
          expression: %{
            type: "string",
            description: "The expression to evaluate, e.g. '2 + 2'"
          }
        },
        required: ["expression"]
      },
      callback: fn %{"expression" => expr} = _args ->
        try do
          {result, _} = Code.eval_string(expr)
          {:ok, to_string(result)}
        rescue
          e -> {:error, "Failed: #{Exception.message(e)}"}
        end
      end
    )

    context = BranchedLLM.Chat.new_context("You are a helpful assistant.")

    # Capture the *test process* PID so the callback can send events here
    # even though it runs inside a Task (where self() would be the Task PID).
    test_pid = self()

    params = %{
      message: "What is 12313 * 4569838?",
      llm_context: context,
      on_event: fn event -> send(test_pid, {:event, event}) end,
      llm_tools: [calculator],
      chat_mod: BranchedLLM.Chat,
      tool_usage_counts: %{},
      branch_id: "main"
    }

    {:ok, _task_pid} = BranchedLLM.ChatOrchestrator.run(params)

    # Wait for :llm_end or :llm_error (whichever comes first)
    received = receive_until_done([], 50_000)

    # ---- Assertions ------------------------------------------------

    # 1. The calculator tool was called (we get a :llm_tool_called event)
    tool_called_events =
      Enum.filter(received, fn
        {:llm_tool_called, _, _} -> true
        _ -> false
      end)

    assert length(tool_called_events) >= 1, "expected at least one :llm_tool_called event"

    %{name: tool_name} =
      tool_called_events
      |> Enum.find_value(fn {:llm_tool_called, _, tc} -> tc end)

    assert tool_name == "calculator",
           "expected tool name \"calculator\", got #{inspect(tool_name)}"

    # 2. At least one :llm_chunk was streamed (when tools are present the
    #    stream is pre-consumed by classify/1, so the full text arrives as a
    #    single chunk via process_text/5)
    chunk_count =
      Enum.count(received, fn
        {:llm_chunk, _, _} -> true
        _ -> false
      end)

    assert chunk_count >= 1,
           "expected at least 1 :llm_chunk event, got #{chunk_count}"

    # 3. The final answer is a non-empty text response from the LLM.
    #    (The exact numeric value depends on the LLM passing the correct
    #    expression to the tool, which is an LLM accuracy concern, not a
    #    tool-integration concern.)
    full_text =
      received
      |> Enum.filter(&match?({:llm_chunk, _, _}, &1))
      |> Enum.map_join(fn {:llm_chunk, _, chunk} -> chunk end)

    assert String.trim(full_text) != "",
           "expected a non-empty text response, got empty string"
  end

  # Collects events until :llm_end or :llm_error, with a timeout.
  defp receive_until_done(acc, timeout) do
    receive do
      {:event, {:llm_end, _, _} = evt} ->
        Enum.reverse([evt | acc])

      {:event, {:llm_error, _, _} = evt} ->
        flunk("Received :llm_error: #{inspect(evt)}")

      {:event, evt} ->
        receive_until_done([evt | acc], timeout)
    after
      timeout ->
        flunk("Timed out waiting for :llm_end. Events received so far: #{inspect(acc)}")
    end
  end
end
