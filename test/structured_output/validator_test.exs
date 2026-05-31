defmodule BranchedLLM.StructuredOutput.ValidatorTest do
  use ExUnit.Case, async: true

  alias BranchedLLM.StructuredOutput.ValidationError
  alias BranchedLLM.StructuredOutput.Validator

  describe "validate/2" do
    test "returns {:ok, map} when JSON matches schema" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "age" => %{"type" => "integer"}
        },
        "required" => ["name", "age"]
      }

      json = ~s({"name": "Alice", "age": 30})

      assert {:ok, %{"name" => "Alice", "age" => 30}} = Validator.validate(json, schema)
    end

    test "returns error when JSON is invalid" do
      schema = %{"type" => "object", "properties" => %{}}

      assert {:error, %ValidationError{message: "Response is not valid JSON"}} =
               Validator.validate("not json at all", schema)
    end

    test "returns error when JSON is not an object" do
      schema = %{"type" => "object", "properties" => %{}}

      assert {:error, %ValidationError{message: "Response is not valid JSON"}} =
               Validator.validate(~s([1, 2, 3]), schema)
    end

    test "returns error when JSON is a bare string" do
      schema = %{"type" => "object", "properties" => %{}}

      assert {:error, %ValidationError{message: "Response is not valid JSON"}} =
               Validator.validate(~s("just a string"), schema)
    end

    test "returns error when JSON does not match schema" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "invoice_number" => %{"type" => "string"},
          "amount" => %{"type" => "number"}
        },
        "required" => ["invoice_number", "amount"]
      }

      json = ~s({"invoice_number": "INV-001"})

      assert {:error, %ValidationError{message: "Schema validation failed"}} =
               Validator.validate(json, schema)
    end

    test "returns error when field has wrong type" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "count" => %{"type" => "integer"}
        },
        "required" => ["count"]
      }

      json = ~s({"count": "not_a_number"})

      assert {:error, %ValidationError{}} = Validator.validate(json, schema)
    end

    test "validates nested objects" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "address" => %{
            "type" => "object",
            "properties" => %{
              "city" => %{"type" => "string"}
            },
            "required" => ["city"]
          }
        },
        "required" => ["address"]
      }

      json = ~s({"address": {"city": "London"}})

      assert {:ok, %{"address" => %{"city" => "London"}}} = Validator.validate(json, schema)
    end

    test "validates enum types" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "status" => %{"enum" => ["active", "inactive"]}
        },
        "required" => ["status"]
      }

      assert {:ok, %{"status" => "active"}} =
               Validator.validate(~s({"status": "active"}), schema)

      assert {:error, %ValidationError{}} =
               Validator.validate(~s({"status": "unknown"}), schema)
    end

    test "allows optional fields to be missing" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "email" => %{"type" => "string"}
        },
        "required" => ["name"]
      }

      assert {:ok, %{"name" => "Bob"}} = Validator.validate(~s({"name": "Bob"}), schema)
    end

    test "returns validation errors as strings" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "x" => %{"type" => "string"}
        },
        "required" => ["x"]
      }

      assert {:error, %ValidationError{validation_errors: errors}} =
               Validator.validate(~s({}), schema)

      assert is_list(errors)

      Enum.each(errors, fn error ->
        assert is_binary(error)
      end)
    end
  end

  describe "check_schema/2" do
    test "returns :ok for valid data" do
      schema = %{
        "type" => "object",
        "properties" => %{"x" => %{"type" => "string"}},
        "required" => ["x"]
      }

      assert :ok = Validator.check_schema(%{"x" => "hello"}, schema)
    end

    test "returns error for invalid data" do
      schema = %{
        "type" => "object",
        "properties" => %{"x" => %{"type" => "string"}},
        "required" => ["x"]
      }

      assert {:error, %ValidationError{}} = Validator.check_schema(%{}, schema)
    end

    test "returns error for wrong type" do
      schema = %{
        "type" => "object",
        "properties" => %{"count" => %{"type" => "integer"}},
        "required" => ["count"]
      }

      assert {:error, %ValidationError{validation_errors: errors}} =
               Validator.check_schema(%{"count" => "not_int"}, schema)

      assert is_list(errors)
    end
  end
end
