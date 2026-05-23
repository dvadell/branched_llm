defmodule BranchedLLM.StructuredOutput.EnforcerJsonSchemaTest do
  use ExUnit.Case, async: true

  alias BranchedLLM.StructuredOutput.Enforcer.JsonSchema

  describe "prepare_request/2" do
    test "injects response_format into provider_options" do
      schema = %{
        "type" => "object",
        "properties" => %{"amount" => %{"type" => "number"}},
        "required" => ["amount"]
      }

      request = %{provider_options: []}

      result = JsonSchema.prepare_request(request, schema)

      expected_format = %{type: "json_schema", json_schema: schema}

      assert Keyword.get(result.provider_options, :response_format) == expected_format
    end

    test "preserves existing provider_options" do
      schema = %{"type" => "object", "properties" => %{}}

      request = %{provider_options: [temperature: 0.7]}

      result = JsonSchema.prepare_request(request, schema)

      assert Keyword.get(result.provider_options, :temperature) == 0.7
      assert Keyword.has_key?(result.provider_options, :response_format)
    end

    test "creates provider_options if missing" do
      schema = %{"type" => "object", "properties" => %{}}

      request = %{}

      result = JsonSchema.prepare_request(request, schema)

      assert Keyword.has_key?(result.provider_options, :response_format)
    end
  end

  describe "extract_response/2" do
    test "extracts JSON from text field" do
      assert {:ok, %{"name" => "test"}} =
               JsonSchema.extract_response(%{text: ~s({"name": "test"})}, %{})
    end

    test "returns error for invalid JSON" do
      assert {:error, :invalid_json} =
               JsonSchema.extract_response(%{text: "not json"}, %{})
    end

    test "extracts JSON from string response" do
      assert {:ok, %{"key" => "val"}} =
               JsonSchema.extract_response(~s({"key": "val"}), %{})
    end
  end
end
