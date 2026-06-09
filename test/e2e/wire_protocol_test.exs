defmodule BranchedLLM.E2E.WireProtocolTest do
  @moduledoc """
  E2E tests for wire protocol inspection — verifying HTTP request
  body contents (response_format presence/absence) and other
  protocol-level concerns.
  """
  use BranchedLLM.E2E.TestCase, async: false

  describe "wire protocol — bypass only" do
    @tag :bypass_only
    test "schema path — sends response_format in HTTP request body", %{bypass: bypass} do
      schema = %{
        "type" => "object",
        "properties" => %{"x" => %{"type" => "string"}},
        "required" => ["x"]
      }

      valid_json = Jason.encode!(%{"x" => "hello"})
      ref = expect_and_inspect_sse(bypass, sse_schema_content(valid_json))

      events = collect_events(default_params(schema: schema))
      body = get_request_body(ref)

      assert Map.has_key?(body, "response_format"),
             "Expected response_format in request body, got keys: #{inspect(Map.keys(body))}"

      assert body["response_format"]["type"] == "json_schema"
      assert find_event(events, :llm_end)
    end

    @tag :bypass_only
    test "non-schema path — does NOT send response_format in HTTP request body", %{
      bypass: bypass
    } do
      ref = expect_and_inspect_sse(bypass, sse_content(["ok"]))

      events = collect_events(default_params())
      body = get_request_body(ref)

      refute Map.has_key?(body, "response_format"),
             "response_format should NOT be in non-schema request body"

      assert find_event(events, :llm_end)
    end
  end
end
