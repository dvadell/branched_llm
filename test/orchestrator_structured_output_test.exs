defmodule BranchedLLM.OrchestratorStructuredOutputTest do
  use ExUnit.Case, async: false

  import Mox

  alias BranchedLLM.ChatOrchestrator
  alias BranchedLLM.LLM.StreamResult.{ContentResult, ToolCallResult}
  alias BranchedLLM.StructuredOutput.ValidationError

  alias ReqLLM.Context
  alias ReqLLM.StreamResponse.MetadataHandle

  setup :set_mox_from_context

  defp make_context do
    Context.new([Context.system("System")])
  end

  defp stream_response(tokens) do
    stream = Stream.map(tokens, &%{text: &1, type: :content})

    {:ok, metadata_handle} = MetadataHandle.start_link(fn -> %{} end)

    %ReqLLM.StreamResponse{
      stream: stream,
      context: Context.new([]),
      model: "gpt-mock",
      cancel: fn -> :ok end,
      metadata_handle: metadata_handle
    }
  end

  describe "run/1 with schema - successful validation" do
    test "emits validated map in llm_end when schema is provided" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "invoice_number" => %{"type" => "string"},
          "amount" => %{"type" => "number"}
        },
        "required" => ["invoice_number", "amount"]
      }

      valid_json = ~s({"invoice_number": "INV-001", "amount": 200.0})

      stub(BranchedLLM.ChatMock, :default_model, fn -> "openai:gpt-4" end)

      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _ctx, _opts ->
        {:ok, %ContentResult{stream: stream_response([valid_json])}}
      end)

      pid = self()

      params = %{
        llm_context: make_context(),
        on_event: fn event -> send(pid, event) end,
        llm_tools: [],
        chat_mod: BranchedLLM.ChatMock,
        tool_usage_counts: %{},
        branch_id: "main",
        schema: schema
      }

      {:ok, _task_pid} = ChatOrchestrator.run(params)

      assert_receive {:llm_chunk, "main", ^valid_json}, 500
      assert_receive {:llm_end, "main", %{"invoice_number" => "INV-001", "amount" => 200.0}}, 500
    end
  end

  describe "run/1 with schema - Anthropic tool coercion" do
    test "intercepts __structured_output__ tool call and returns validated map" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "result" => %{"type" => "string"}
        },
        "required" => ["result"]
      }

      tool_call =
        ReqLLM.ToolCall.new(
          "call_structured",
          "__structured_output__",
          ~s({"result": "success"})
        )

      stub(BranchedLLM.ChatMock, :default_model, fn -> "anthropic:claude-3-sonnet" end)

      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _ctx, _opts ->
        {:ok, %ToolCallResult{tool_calls: [tool_call], context: make_context()}}
      end)

      pid = self()

      params = %{
        llm_context: make_context(),
        on_event: fn event -> send(pid, event) end,
        llm_tools: [],
        chat_mod: BranchedLLM.ChatMock,
        tool_usage_counts: %{},
        branch_id: "main",
        schema: schema
      }

      {:ok, _task_pid} = ChatOrchestrator.run(params)

      assert_receive {:llm_end, "main", %{"result" => "success"}}, 500
    end
  end

  describe "run/1 with schema - validation failure with retries" do
    test "emits ValidationError when all retries are exhausted" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "invoice_number" => %{"type" => "string"},
          "amount" => %{"type" => "number"}
        },
        "required" => ["invoice_number", "amount"]
      }

      # First call returns invalid JSON (missing "amount")
      invalid_json = ~s({"invoice_number": "INV-001"})

      stub(BranchedLLM.ChatMock, :default_model, fn -> "openai:gpt-4" end)

      # First call (original) - returns invalid
      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _ctx, _opts ->
        {:ok, %ContentResult{stream: stream_response([invalid_json])}}
      end)

      # Retry attempts - also return invalid
      expect(BranchedLLM.ChatMock, :send_message_stream, 2, fn _ctx, _opts ->
        {:ok, %ContentResult{stream: stream_response([invalid_json])}}
      end)

      pid = self()

      params = %{
        llm_context: make_context(),
        on_event: fn event -> send(pid, event) end,
        llm_tools: [],
        chat_mod: BranchedLLM.ChatMock,
        tool_usage_counts: %{},
        branch_id: "main",
        schema: schema,
        schema_max_retries: 2
      }

      {:ok, _task_pid} = ChatOrchestrator.run(params)

      assert_receive {:llm_error, "main", %ValidationError{} = error}, 2000
      assert error.message =~ "Schema validation failed after 3 attempts"
    end

    test "succeeds after retry with valid response" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"}
        },
        "required" => ["name"]
      }

      invalid_json = ~s({"wrong": "field"})
      valid_json = ~s({"name": "Alice"})

      stub(BranchedLLM.ChatMock, :default_model, fn -> "openai:gpt-4" end)

      # First call returns invalid
      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _ctx, _opts ->
        {:ok, %ContentResult{stream: stream_response([invalid_json])}}
      end)

      # Retry returns valid
      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _ctx, _opts ->
        {:ok, %ContentResult{stream: stream_response([valid_json])}}
      end)

      pid = self()

      params = %{
        llm_context: make_context(),
        on_event: fn event -> send(pid, event) end,
        llm_tools: [],
        chat_mod: BranchedLLM.ChatMock,
        tool_usage_counts: %{},
        branch_id: "main",
        schema: schema,
        schema_max_retries: 2
      }

      {:ok, _task_pid} = ChatOrchestrator.run(params)

      assert_receive {:llm_end, "main", %{"name" => "Alice"}}, 2000
    end
  end

  describe "run/1 with schema - non-JSON response" do
    test "emits ValidationError when response is not JSON" do
      schema = %{
        "type" => "object",
        "properties" => %{"x" => %{"type" => "string"}},
        "required" => ["x"]
      }

      stub(BranchedLLM.ChatMock, :default_model, fn -> "openai:gpt-4" end)

      expect(BranchedLLM.ChatMock, :send_message_stream, 3, fn _ctx, _opts ->
        {:ok, %ContentResult{stream: stream_response(["I am a text response, not JSON"])}}
      end)

      pid = self()

      params = %{
        llm_context: make_context(),
        on_event: fn event -> send(pid, event) end,
        llm_tools: [],
        chat_mod: BranchedLLM.ChatMock,
        tool_usage_counts: %{},
        branch_id: "main",
        schema: schema,
        schema_max_retries: 2
      }

      {:ok, _task_pid} = ChatOrchestrator.run(params)

      assert_receive {:llm_error, "main", %ValidationError{}}, 2000
    end
  end

  describe "run/1 without schema" do
    test "emits full text as before (backward compatibility)" do
      stub(BranchedLLM.ChatMock, :default_model, fn -> "openai:gpt-4" end)

      expect(BranchedLLM.ChatMock, :send_message_stream, 1, fn _ctx, _opts ->
        {:ok, %ContentResult{stream: stream_response(["Hello", " world"])}}
      end)

      pid = self()

      params = %{
        llm_context: make_context(),
        on_event: fn event -> send(pid, event) end,
        llm_tools: [],
        chat_mod: BranchedLLM.ChatMock,
        tool_usage_counts: %{},
        branch_id: "main"
      }

      {:ok, _task_pid} = ChatOrchestrator.run(params)

      assert_receive {:llm_chunk, "main", "Hello"}, 500
      assert_receive {:llm_chunk, "main", " world"}, 500
      assert_receive {:llm_end, "main", "Hello world"}, 500
    end
  end
end
