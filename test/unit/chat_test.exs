defmodule BranchedLLM.ChatTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias BranchedLLM.Chat
  alias Plug.Conn
  alias ReqLLM.Context

  describe "new_context/1" do
    test "creates context with system prompt" do
      context = Chat.new_context("You are a helpful assistant")
      assert %Context{} = context
      assert length(context.messages) == 1

      [msg] = context.messages
      assert msg.role == :system
      assert [%{type: :text, text: "You are a helpful assistant"}] = msg.content
    end
  end

  describe "get_history/1" do
    test "returns messages from context" do
      context = Chat.new_context("System prompt")
      assert Chat.get_history(context) == context.messages
    end

    test "returns all messages including user messages" do
      context =
        Chat.new_context("System prompt")
        |> Context.append(Context.user("Hello"))

      history = Chat.get_history(context)
      assert length(history) == 2

      roles = Enum.map(history, & &1.role)
      assert roles == [:system, :user]
    end
  end

  describe "reset_context/1" do
    test "keeps system messages and removes user/assistant messages" do
      context =
        Chat.new_context("You are a helpful assistant")
        |> Context.append(Context.user("Hello"))
        |> Context.append(Context.assistant("Hi there!"))

      reset = Chat.reset_context(context)
      assert length(reset.messages) == 1
      assert hd(reset.messages).role == :system
    end

    test "returns empty context when there is no system prompt" do
      context = Context.new([Context.user("Hello")])
      reset = Chat.reset_context(context)
      assert reset.messages == []
    end
  end

  describe "health_check/1" do
    setup do
      bypass = Bypass.open()
      base_url = "http://localhost:#{bypass.port}"

      Application.put_env(:branched_llm, :base_url, base_url <> "/v1")
      Application.put_env(:branched_llm, :ai_model, "ollama:test-model")

      on_exit(fn ->
        Application.delete_env(:branched_llm, :base_url)
        Application.delete_env(:branched_llm, :ai_model)
      end)

      {:ok, bypass: bypass}
    end

    test "returns :ok on 200 response", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/api/tags", fn conn ->
        Conn.send_resp(conn, 200, "ok")
      end)

      assert Chat.health_check() == :ok
    end

    test "returns {:error, :unavailable} on non-200 status", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/api/tags", fn conn ->
        Conn.send_resp(conn, 503, "unavailable")
      end)

      assert Chat.health_check() == {:error, :unavailable}
    end

    test "returns {:error, :unavailable} on connection error", %{bypass: bypass} do
      Bypass.down(bypass)

      assert Chat.health_check() == {:error, :unavailable}
    end
  end

  describe "send_message/3" do
    setup do
      bypass = Bypass.open()
      base_url = "http://localhost:#{bypass.port}/v1"

      Application.put_env(:branched_llm, :base_url, base_url)
      Application.put_env(:branched_llm, :ai_model, "ollama:test-model")

      on_exit(fn ->
        Application.delete_env(:branched_llm, :base_url)
        Application.delete_env(:branched_llm, :ai_model)
      end)

      {:ok, bypass: bypass}
    end

    test "sends message and returns response and updated context", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Conn.put_resp_header("content-type", "text/event-stream")
        |> Conn.put_resp_header("cache-control", "no-cache")
        |> Conn.send_resp(200, sse_content(["Hello, world!"]))
      end)

      context = Chat.new_context("You are helpful.")
      assert {:ok, "Hello, world!", new_context} = Chat.send_message("Hi", context)
      assert length(new_context.messages) == 3
    end

    test "handles LLM failure gracefully", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Conn.put_resp_header("content-type", "application/json")
        |> Conn.send_resp(500, Jason.encode!(%{"error" => %{"message" => "Server error"}}))
      end)

      context = Chat.new_context("You are helpful.")

      _log =
        capture_log(fn ->
          result = Chat.send_message("Hi", context)
          assert elem(result, 0) in [:ok, :error]
        end)
    end

    test "returns validated map when schema is provided", %{bypass: bypass} do
      schema = %{
        "type" => "object",
        "properties" => %{"sentiment" => %{"type" => "string"}},
        "required" => ["sentiment"]
      }

      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Conn.put_resp_header("content-type", "text/event-stream")
        |> Conn.put_resp_header("cache-control", "no-cache")
        |> Conn.send_resp(
          200,
          sse_content([Jason.encode!(%{"sentiment" => "positive"})])
        )
      end)

      context = Chat.new_context("Analyze sentiment.")
      assert {:ok, result, _new_context} = Chat.send_message("Great!", context, schema: schema)
      assert result["sentiment"] == "positive"
    end
  end

  # ---------------------------------------------------------------------------
  # SSE helpers
  # ---------------------------------------------------------------------------

  defp sse_content(chunks, opts \\ []) do
    model = Keyword.get(opts, :model, "test-model")
    id = Keyword.get(opts, :id, "chatcmpl-test")

    content_events =
      chunks
      |> Enum.with_index()
      |> Enum.map(fn {chunk, i} ->
        delta =
          if i == 0 do
            %{"role" => "assistant", "content" => chunk}
          else
            %{"content" => chunk}
          end

        sse_data(%{
          "id" => id,
          "object" => "chat.completion.chunk",
          "created" => 0,
          "model" => model,
          "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => nil}]
        })
      end)

    finish =
      sse_data(%{
        "id" => id,
        "object" => "chat.completion.chunk",
        "created" => 0,
        "model" => model,
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
      })

    usage =
      sse_data(%{
        "id" => id,
        "object" => "chat.completion.chunk",
        "created" => 0,
        "model" => model,
        "choices" => [],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 20, "total_tokens" => 30}
      })

    done = "data: [DONE]\n\n"

    Enum.join(content_events ++ [finish, usage, done])
  end

  defp sse_data(map) do
    "data: #{Jason.encode!(map)}\n\n"
  end
end
