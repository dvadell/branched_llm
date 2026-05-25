defmodule BranchedLLM.StructuredOutput.EnforcerPromptTest do
  use ExUnit.Case, async: true

  alias BranchedLLM.StructuredOutput.Enforcer.Prompt

  describe "prepare_request/2" do
    test "appends schema instruction to system_prompt" do
      schema = %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}}
      }

      request = %{system_prompt: "You are helpful.", context: nil}

      result = Prompt.prepare_request(request, schema)

      assert String.contains?(result.system_prompt, "You are helpful.")
      assert String.contains?(result.system_prompt, "valid JSON matching this schema")
      assert String.contains?(result.system_prompt, ~s("type": "object"))
    end

    test "adds schema instruction even without existing system_prompt" do
      schema = %{"type" => "object", "properties" => %{}}
      request = %{context: nil}

      result = Prompt.prepare_request(request, schema)

      assert String.contains?(result.system_prompt, "valid JSON matching this schema")
    end

    test "defaults system_prompt to empty string when nil" do
      schema = %{"type" => "object", "properties" => %{}}
      request = %{context: nil}

      result = Prompt.prepare_request(request, schema)

      assert is_binary(result.system_prompt)
    end
  end

  describe "extract_response/2 with text map" do
    test "extracts plain JSON from text" do
      assert {:ok, %{"key" => "val"}} = Prompt.extract_response(%{text: ~s({"key": "val"})}, %{})
    end

    test "strips markdown code fences from text" do
      text = "```json\n{\"key\": \"val\"}\n```"

      assert {:ok, %{"key" => "val"}} = Prompt.extract_response(%{text: text}, %{})
    end

    test "strips code fences without json label from text" do
      text = "```\n{\"key\": \"val\"}\n```"

      assert {:ok, %{"key" => "val"}} = Prompt.extract_response(%{text: text}, %{})
    end

    test "returns error for invalid JSON in text" do
      assert {:error, :invalid_json} = Prompt.extract_response(%{text: "just plain text"}, %{})
    end

    test "returns error when JSON in text is not an object" do
      assert {:error, :invalid_json} = Prompt.extract_response(%{text: ~s([1, 2, 3])}, %{})
    end
  end

  describe "extract_response/2 with raw string (fallback clause)" do
    test "extracts JSON from raw string response" do
      assert {:ok, %{"key" => "val"}} = Prompt.extract_response(~s({"key": "val"}), %{})
    end

    test "strips markdown code fences from raw string" do
      text = "```json\n{\"key\": \"val\"}\n```"

      assert {:ok, %{"key" => "val"}} = Prompt.extract_response(text, %{})
    end

    test "returns error for invalid JSON in raw string" do
      assert {:error, :invalid_json} = Prompt.extract_response("just plain text", %{})
    end

    test "returns error when raw string decodes to non-map JSON" do
      assert {:error, :invalid_json} = Prompt.extract_response(~s([1, 2, 3]), %{})
    end
  end

  describe "extract_response/2 with unsupported format" do
    test "returns error for non-string, non-map response" do
      assert {:error, :unsupported_response_format} = Prompt.extract_response(123, %{})
    end

    test "returns error for atom response" do
      assert {:error, :unsupported_response_format} = Prompt.extract_response(:something, %{})
    end
  end

  describe "strip_json_fences/1" do
    test "strips ```json fences" do
      assert Prompt.strip_json_fences("```json\n{\"a\": 1}\n```") == "{\"a\": 1}"
    end

    test "strips ``` fences without label" do
      assert Prompt.strip_json_fences("```\n{\"a\": 1}\n```") == "{\"a\": 1}"
    end

    test "returns trimmed text when no fences" do
      assert Prompt.strip_json_fences("{\"a\": 1}") == "{\"a\": 1}"
    end

    test "handles leading/trailing whitespace" do
      assert Prompt.strip_json_fences(" {\"a\": 1} ") == "{\"a\": 1}"
    end
  end
end
