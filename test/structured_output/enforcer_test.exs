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
    end
  end

  describe "prepare_request/3" do
    test "dispatches to correct enforcer" do
      schema = %{"type" => "object", "properties" => %{}}
      request = %{}

      result = Enforcer.prepare_request(:openai, request, schema)

      assert Keyword.get(result.provider_options, :response_format) == %{
               type: "json_schema",
               json_schema: schema
             }
    end
  end

  describe "extract_response/3" do
    test "dispatches to correct enforcer for text response" do
      schema = %{"type" => "object", "properties" => %{}}
      raw_response = %{text: ~s({"key": "value"})}

      assert {:ok, %{"key" => "value"}} =
               Enforcer.extract_response(:openai, raw_response, schema)
    end
  end
end
