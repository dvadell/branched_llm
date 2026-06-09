# Run manually: mix run manual_tests/schema_integration_test.exs
#
# Requires a configured LLM (e.g. Ollama, OpenAI) available at whatever
# config/config.exs points to. No mocks — this hits a real provider.

ExUnit.start()

defmodule BranchedLLM.Integration.SchemaTest do
  use ExUnit.Case, async: false

  @tag timeout: 60_000
  test "Chat.send_message/3 with schema returns a validated map" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "sentiment" => %{"type" => "string", "enum" => ["positive", "negative", "neutral"]},
        "confidence" => %{"type" => "number"},
        "keywords" => %{"type" => "array", "items" => %{"type" => "string"}}
      },
      "required" => ["sentiment", "confidence", "keywords"]
    }

    context = BranchedLLM.Chat.new_context("You are a sentiment analyzer")

    {:ok, result, _ctx} =
      BranchedLLM.Chat.send_message(
        "Analyze: 'I absolutely love this product!'",
        context,
        schema: schema,
        schema_max_retries: 3
      )

    # The result should be a validated map, not raw text
    assert is_map(result), "expected a map, got #{inspect(result)}"

    for key <- ["sentiment", "confidence", "keywords"] do
      assert Map.has_key?(result, key),
             "expected key #{inspect(key)} in result, got #{inspect(Map.keys(result))}"
    end

    assert result["sentiment"] in ["positive", "negative", "neutral"],
           "expected sentiment to be one of the enum values, got #{inspect(result["sentiment"])}"

    assert is_number(result["confidence"]),
           "expected confidence to be a number, got #{inspect(result["confidence"])}"

    assert is_list(result["keywords"]),
           "expected keywords to be a list, got #{inspect(result["keywords"])}"
  end

  @tag timeout: 60_000
  test "LLM returns structured output matching the invoice schema" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "invoice_number" => %{"type" => "string"},
        "amount" => %{"type" => "number"},
        "due_date" => %{"type" => "string"}
      },
      "required" => ["invoice_number", "amount", "due_date"]
    }

    context =
      "You are an invoice parser"
      |> BranchedLLM.Chat.new_context()
      |> ReqLLM.Context.append(
        ReqLLM.Context.user("Extract: Invoice INV-2024-089 for $450.00 due July 1, 2024")
      )

    # Capture the *test process* PID so the callback can send events here
    # even though it runs inside a Task (where self() would be the Task PID).
    test_pid = self()

    params = %{
      llm_context: context,
      on_event: fn event -> send(test_pid, {:event, event}) end,
      chat_mod: BranchedLLM.Chat,
      branch_id: "main",
      schema: schema,
      schema_max_retries: 3
    }

    {:ok, _task_pid} = BranchedLLM.ChatOrchestrator.run(params)

    # Wait for :llm_end or :llm_error (whichever comes first)
    received = receive_until_done([], 50_000)

    # ---- Assertions ------------------------------------------------

    # 1. The :llm_end event delivers a validated map (not raw text)
    #    when a schema is provided.
    llm_end_events =
      Enum.filter(received, fn
        {:llm_end, _, _} -> true
        _ -> false
      end)

    assert length(llm_end_events) >= 1, "expected at least one :llm_end event"

    {:llm_end, _, validated_map} = List.first(llm_end_events)

    assert is_map(validated_map), "expected a map from :llm_end, got #{inspect(validated_map)}"

    # 2. All required keys are present
    for key <- ["invoice_number", "amount", "due_date"] do
      assert Map.has_key?(validated_map, key),
             "expected key #{inspect(key)} in validated map, got #{inspect(Map.keys(validated_map))}"
    end

    # 3. Types match the schema (string for invoice_number & due_date,
    #    number for amount)
    assert is_binary(validated_map["invoice_number"]),
           "expected invoice_number to be a string, got #{inspect(validated_map["invoice_number"])}"

    assert is_number(validated_map["amount"]),
           "expected amount to be a number, got #{inspect(validated_map["amount"])}"

    assert is_binary(validated_map["due_date"]),
           "expected due_date to be a string, got #{inspect(validated_map["due_date"])}"
  end

  # Collects events until :llm_end or :llm_error, with a timeout.
  defp receive_until_done(acc, timeout) do
    receive do
      {:event, {:llm_end, _, _} = evt} -> Enum.reverse([evt | acc])
      {:event, {:llm_error, _, %BranchedLLM.StructuredOutput.ValidationError{} = err}} ->
        flunk("Schema validation exhausted after retries: #{inspect(err)}")
      {:event, {:llm_error, _, _} = evt} -> flunk("Received :llm_error: #{inspect(evt)}")
      {:event, evt} -> receive_until_done([evt | acc], timeout)
    after
      timeout -> flunk("Timed out waiting for :llm_end. Events received so far: #{inspect(acc)}")
    end
  end
end
