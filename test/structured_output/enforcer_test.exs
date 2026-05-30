defmodule BranchedLLM.StructuredOutput.EnforcerTest do
  use ExUnit.Case, async: true

  alias BranchedLLM.StructuredOutput.Enforcer

  describe "enforcer_for/1" do
    test "returns JsonSchema for :openai" do
      assert Enforcer.enforcer_for(:openai) ==
               BranchedLLM.StructuredOutput.Enforcer.JsonSchema
    end

    test "returns ToolCoerce for :anthropic" do
      assert Enforcer.enforcer_for(:anthropic) ==
               BranchedLLM.StructuredOutput.Enforcer.ToolCoerce
    end

    test "returns Grammar for :ollama" do
      assert Enforcer.enforcer_for(:ollama) ==
               BranchedLLM.StructuredOutput.Enforcer.Grammar
    end

    test "returns Grammar for :llamacpp" do
      assert Enforcer.enforcer_for(:llamacpp) ==
               BranchedLLM.StructuredOutput.Enforcer.Grammar
    end

    test "returns Prompt for unknown providers" do
      assert Enforcer.enforcer_for(:unknown) ==
               BranchedLLM.StructuredOutput.Enforcer.Prompt
    end

    test "returns Prompt for :vllm" do
      assert Enforcer.enforcer_for(:vllm) ==
               BranchedLLM.StructuredOutput.Enforcer.Prompt
    end

    test "returns Prompt for any other atom" do
      assert Enforcer.enforcer_for(:some_random_provider) ==
               BranchedLLM.StructuredOutput.Enforcer.Prompt
    end
  end

  describe "structured_output_tool_name/0" do
    test "returns reserved tool name" do
      assert Enforcer.structured_output_tool_name() == "__structured_output__"
    end
  end

  describe "build_synthetic_tool/1" do
    test "builds tool definition with schema as parameters" do
      schema = %{
        "type" => "object",
        "properties" => %{"amount" => %{"type" => "number"}}
      }

      tool = Enforcer.build_synthetic_tool(schema)

      assert tool["function"]["name"] == "__structured_output__"
      assert tool["function"]["parameters"] == schema
      assert tool["type"] == "function"
      assert tool["function"]["description"] =~ "structured data"
    end
  end

  describe "resolve_provider/1" do
    test "resolves provider from valid model string" do
      result = Enforcer.resolve_provider("ollama:cara-cpu")
      assert result == :ollama
    end

    test "returns :unknown for invalid model string" do
      assert Enforcer.resolve_provider("totally_invalid_model_string_xyz") == :unknown
    end

    test "returns :unknown for unregistered provider" do
      # :httpc is an existing Erlang atom but not a registered ReqLLM provider
      assert is_atom(:httpc)
      assert Enforcer.resolve_provider("httpc:some-model") == :unknown
    end

    test "returns :unknown for non-atom provider prefix" do
      # Use a random string that is extremely unlikely to be an existing atom
      random_provider = "x_#{:erlang.unique_integer([:positive])}_not_an_atom"
      assert Enforcer.resolve_provider("#{random_provider}:model") == :unknown
    end
  end

  describe "resolve_provider/1 with LLMDB.Model struct" do
    test "resolves provider from valid LLMDB.Model struct" do
      model = %LLMDB.Model{provider: :openai, id: "gpt-4"}
      result = Enforcer.resolve_provider(model)
      assert result == :openai
    end

    test "returns :unknown for LLMDB.Model with unregistered provider" do
      model = %LLMDB.Model{provider: :httpc, id: "some-model"}
      result = Enforcer.resolve_provider(model)
      assert result == :unknown
    end
  end

  describe "resolve_provider/1 with unsupported input" do
    test "returns :unknown for non-string, non-struct input" do
      assert Enforcer.resolve_provider(nil) == :unknown
      assert Enforcer.resolve_provider(123) == :unknown
      assert Enforcer.resolve_provider([]) == :unknown
    end
  end

  describe "prepare_request/3" do
    test "dispatches to correct enforcer for OpenAI" do
      schema = %{"type" => "object", "properties" => %{}}
      request = %{}

      result = Enforcer.prepare_request(:openai, request, schema)

      assert Keyword.get(result.provider_options, :response_format) == %{
               type: "json_schema",
               json_schema: schema
             }
    end

    test "dispatches to correct enforcer for Anthropic" do
      schema = %{"type" => "object", "properties" => %{}}
      request = %{tools: []}

      result = Enforcer.prepare_request(:anthropic, request, schema)

      assert Map.has_key?(result, :tool_choice)
    end

    test "dispatches to correct enforcer for Ollama" do
      schema = %{"type" => "object", "properties" => %{}}
      request = %{provider_options: []}

      result = Enforcer.prepare_request(:ollama, request, schema)

      assert Keyword.get(result.provider_options, :response_format) == %{
               type: "json_schema",
               json_schema: schema
             }
    end

    test "dispatches to fallback enforcer for unknown" do
      schema = %{"type" => "object", "properties" => %{}}
      request = %{context: nil}

      result = Enforcer.prepare_request(:unknown_provider, request, schema)

      assert Map.has_key?(result, :system_prompt)
      assert result.system_prompt =~ "valid JSON"
    end
  end

  describe "extract_response/3" do
    test "dispatches to correct enforcer for text response" do
      schema = %{"type" => "object", "properties" => %{}}
      raw_response = %{text: ~s({"key": "value"})}

      assert {:ok, %{"key" => "value"}} =
               Enforcer.extract_response(:openai, raw_response, schema)
    end

    test "dispatches to ToolCoerce for Anthropic tool_calls" do
      schema = %{"type" => "object", "properties" => %{}}

      tool_call =
        ReqLLM.ToolCall.new("call_1", "__structured_output__", ~s({"key": "value"}))

      raw_response = %{tool_calls: [tool_call]}

      assert {:ok, %{"key" => "value"}} =
               Enforcer.extract_response(:anthropic, raw_response, schema)
    end
  end
end
