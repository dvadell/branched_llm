defmodule BranchedLLM.StructuredOutput.EnforcerGrammarTest do
  use ExUnit.Case, async: true

  alias BranchedLLM.StructuredOutput.Enforcer.Grammar

  describe "prepare_request/2" do
    test "injects schema as format in provider_options" do
      schema = %{
        "type" => "object",
        "properties" => %{"amount" => %{"type" => "number"}}
      }

      request = %{provider_options: []}

      result = Grammar.prepare_request(request, schema)

      assert Keyword.get(result.provider_options, :format) == schema
    end

    test "preserves existing provider_options" do
      schema = %{"type" => "object", "properties" => %{}}
      request = %{provider_options: [temperature: 0.5]}

      result = Grammar.prepare_request(request, schema)

      assert Keyword.get(result.provider_options, :temperature) == 0.5
      assert Keyword.get(result.provider_options, :format) == schema
    end
  end

  describe "extract_response/2" do
    test "extracts JSON from text field" do
      assert {:ok, %{"x" => 1}} =
               Grammar.extract_response(%{text: ~s({"x": 1})}, %{})
    end

    test "returns error for invalid JSON" do
      assert {:error, :invalid_json} =
               Grammar.extract_response(%{text: "bad"}, %{})
    end
  end
end
