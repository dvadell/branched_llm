defmodule BranchedLLM.LLMErrorFormatterTest do
  use ExUnit.Case, async: true
  alias BranchedLLM.LLMErrorFormatter

  describe "format/1" do
    test "formats rate limit error with retry delay" do
      error = %ReqLLM.Error.API.Request{
        status: 429,
        reason: "Too many requests",
        response_body: %{
          "details" => [
            %{
              "@type" => "type.googleapis.com/google.rpc.RetryInfo",
              "retryDelay" => "30s"
            }
          ]
        }
      }

      result = LLMErrorFormatter.format(error)

      assert result =~ "The AI is busy"
      assert result =~ "retry in 30s"
    end

    test "formats rate limit error without retry delay" do
      error = %ReqLLM.Error.API.Request{
        status: 429,
        reason: "Too many requests",
        response_body: %{"details" => []}
      }

      result = LLMErrorFormatter.format(error)

      assert result == "The AI is busy. Wait a moment and try again later."
    end

    test "formats generic API error" do
      error = %ReqLLM.Error.API.Request{status: 500, reason: "Internal error"}

      result = LLMErrorFormatter.format(error)

      assert result == "API error (status 500). Please try again."
    end

    test "formats generic exception" do
      error = RuntimeError.exception("something went wrong")

      result = LLMErrorFormatter.format(error)

      assert result =~ "Error:"
      assert result =~ "something went wrong"
    end
  end
end
