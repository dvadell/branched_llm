defmodule BranchedLLM.StructuredOutput.ValidationErrorTest do
  use ExUnit.Case, async: true

  alias BranchedLLM.StructuredOutput.ValidationError

  describe "ValidationError struct" do
    test "creates error with required message" do
      error = %ValidationError{message: "test error"}

      assert error.message == "test error"
      assert error.last_response == nil
      assert error.validation_errors == nil
    end

    test "creates error with all fields" do
      error = %ValidationError{
        message: "Schema validation failed",
        last_response: ~s({"bad": "data"}),
        validation_errors: ["field X is required"]
      }

      assert error.message == "Schema validation failed"
      assert error.last_response == ~s({"bad": "data"})
      assert error.validation_errors == ["field X is required"]
    end
  end
end
