defmodule BranchedLLM.StructuredOutput.EnforcerGrammarTest do
  use ExUnit.Case, async: true

  alias BranchedLLM.StructuredOutput.Enforcer.Grammar

  describe "prepare_request/2" do
    test "injects schema as response_format in provider_options" do
      schema = %{
        "type" => "object",
        "properties" => %{"amount" => %{"type" => "number"}}
      }

      request = %{provider_options: []}
      result = Grammar.prepare_request(request, schema)

      expected_format = %{type: "json_schema", json_schema: schema}
      assert Keyword.get(result.provider_options, :response_format) == expected_format
    end

    test "preserves existing provider_options" do
      schema = %{"type" => "object", "properties" => %{}}
      request = %{provider_options: [temperature: 0.5]}
      result = Grammar.prepare_request(request, schema)

      assert Keyword.get(result.provider_options, :temperature) == 0.5

      assert Keyword.get(result.provider_options, :response_format) == %{
               type: "json_schema",
               json_schema: schema
             }
    end

    test "creates provider_options if not present" do
      schema = %{"type" => "object", "properties" => %{}}
      request = %{}
      result = Grammar.prepare_request(request, schema)

      assert Keyword.get(result.provider_options, :response_format) == %{
               type: "json_schema",
               json_schema: schema
             }
    end
  end

  describe "extract_response/2 with text map" do
    test "extracts JSON from text field" do
      assert {:ok, %{"x" => 1}} = Grammar.extract_response(%{text: ~s({"x": 1})}, %{})
    end

    test "returns error for invalid JSON in text field" do
      assert {:error, :invalid_json} = Grammar.extract_response(%{text: "bad"}, %{})
    end

    test "returns error when JSON is not an object" do
      assert {:error, :invalid_json} = Grammar.extract_response(%{text: ~s([1,2,3])}, %{})
    end
  end

  describe "extract_response/2 with raw string (fallback clause)" do
    test "extracts JSON from raw string response" do
      assert {:ok, %{"x" => 1}} = Grammar.extract_response(~s({"x": 1}), %{})
    end

    test "returns error for invalid JSON in raw string" do
      assert {:error, :invalid_json} = Grammar.extract_response("not json", %{})
    end

    test "returns error when raw string JSON is not an object" do
      assert {:error, :invalid_json} = Grammar.extract_response(~s("just a string"), %{})
    end
  end
end
