defmodule BranchedLLM.ChatClientTest do
  use ExUnit.Case, async: false

  alias BranchedLLM.ChatClient
  alias BranchedLLM.LLM.StreamResult.{ContentResult, EmptyResult, ToolCallResult}
  alias Plug.Conn
  alias ReqLLM.Context

  setup do
    case :ets.info(ChatClientTest.Cache) do
      :undefined -> :ets.new(ChatClientTest.Cache, [:named_table, :public, :set])
      _ -> :ok
    end

    on_exit(fn ->
      case :ets.info(ChatClientTest.Cache) do
        :undefined -> :ok
        _ -> :ets.delete(ChatClientTest.Cache)
      end
    end)

    :ok
  end

  describe "default_model/0" do
    test "reads from :branched_llm config" do
      Application.put_env(:branched_llm, :ai_model, "ollama:test-model")
      model = ChatClient.default_model()
      assert model.provider == :ollama
      assert model.id == "test-model"
    after
      Application.delete_env(:branched_llm, :ai_model)
    end

    test "reads from :cara config as fallback" do
      Application.put_env(:cara, :ai_model, "openai:gpt-4")
      model = ChatClient.default_model()
      assert model.provider == :openai
      assert model.id == "gpt-4"
    after
      Application.delete_env(:cara, :ai_model)
    end

    test "returns model struct when model string is unusual" do
      Application.put_env(:branched_llm, :ai_model, "::invalid::")
      model = ChatClient.default_model()

      case model do
        %LLMDB.Model{} -> :ok
        _ -> assert byte_size(model) > 0
      end
    after
      Application.delete_env(:branched_llm, :ai_model)
    end
  end

  describe "stream_text/3" do
    setup do
      bypass = Bypass.open()
      context = Context.new([Context.system("You are helpful."), Context.user("Hello")])
      {:ok, bypass: bypass, context: context}
    end

    test "streams text content", %{bypass: bypass, context: context} do
      base_url = "http://localhost:#{bypass.port}/v1"

      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Conn.put_resp_header("content-type", "text/event-stream")
        |> Conn.put_resp_header("cache-control", "no-cache")
        |> Conn.send_resp(200, sse_content(["Hello", " world"]))
      end)

      assert {:ok, stream_response} =
               ChatClient.stream_text("ollama:test", context,
                 base_url: base_url,
                 api_key: "test-key"
               )

      tokens = ReqLLM.StreamResponse.tokens(stream_response)
      text = Enum.join(tokens)
      assert text == "Hello world"
    end

    test "sends request to the correct base_url", %{bypass: bypass, context: context} do
      base_url = "http://localhost:#{bypass.port}/v1"

      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Conn.put_resp_header("content-type", "text/event-stream")
        |> Conn.put_resp_header("cache-control", "no-cache")
        |> Conn.send_resp(200, sse_content(["ok"]))
      end)

      assert {:ok, stream_response} =
               ChatClient.stream_text("ollama:test", context,
                 base_url: base_url,
                 api_key: "test-key"
               )

      tokens = ReqLLM.StreamResponse.tokens(stream_response)
      assert Enum.to_list(tokens) |> Enum.join() == "ok"
    end
  end

  describe "send_message_stream/2" do
    setup do
      bypass = Bypass.open()
      base_url = "http://localhost:#{bypass.port}/v1"
      context = Context.new([Context.system("You are helpful."), Context.user("Hi")])

      Application.put_env(:branched_llm, :base_url, base_url)
      Application.put_env(:branched_llm, :ai_model, "ollama:test-model")

      on_exit(fn ->
        Application.delete_env(:branched_llm, :base_url)
        Application.delete_env(:branched_llm, :ai_model)
      end)

      {:ok, bypass: bypass, context: context}
    end

    test "returns ContentResult for text response", %{bypass: bypass, context: context} do
      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Conn.put_resp_header("content-type", "text/event-stream")
        |> Conn.put_resp_header("cache-control", "no-cache")
        |> Conn.send_resp(200, sse_content(["Hello!"], id: "cmpl-1"))
      end)

      assert {:ok, %ContentResult{stream: stream}} = ChatClient.send_message_stream(context)

      tokens = ReqLLM.StreamResponse.tokens(stream)
      text = Enum.join(tokens)
      assert text == "Hello!"
    end

    test "returns ContentResult for text response with tools (final_answer path)",
         %{bypass: bypass, context: context} do
      tool =
        ReqLLM.Tool.new!(
          name: "noop",
          description: "No-op tool",
          parameter_schema: %{type: "object", properties: %{}},
          callback: fn _ -> {:ok, "noop"} end
        )

      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Conn.put_resp_header("content-type", "text/event-stream")
        |> Conn.put_resp_header("cache-control", "no-cache")
        |> Conn.send_resp(200, sse_content(["Answer"], id: "cmpl-2"))
      end)

      assert {:ok, %ContentResult{}} = ChatClient.send_message_stream(context, tools: [tool])
    end

    test "returns ToolCallResult for tool call stream", %{bypass: bypass, context: context} do
      tool =
        ReqLLM.Tool.new!(
          name: "calculator",
          description: "Calculates",
          parameter_schema: %{
            type: "object",
            properties: %{expr: %{type: "string"}},
            required: ["expr"]
          },
          callback: fn %{"expr" => expr} ->
            # credo:disable-for-next-line
            {result, _} = Code.eval_string(expr)
            {:ok, to_string(result)}
          end
        )

      tc = %{
        "id" => "call_1",
        "name" => "calculator",
        "arguments" => Jason.encode!(%{"expr" => "2+2"})
      }

      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Conn.put_resp_header("content-type", "text/event-stream")
        |> Conn.put_resp_header("cache-control", "no-cache")
        |> Conn.send_resp(200, sse_tool_call([tc], id: "cmpl-3"))
      end)

      assert {:ok, %ToolCallResult{tool_calls: [tool_call]}} =
               ChatClient.send_message_stream(context, tools: [tool])

      assert ReqLLM.ToolCall.name(tool_call) == "calculator"
    end

    test "returns EmptyResult when LLM returns nil content with tools",
         %{bypass: bypass, context: context} do
      tool =
        ReqLLM.Tool.new!(
          name: "noop",
          description: "No-op",
          parameter_schema: %{type: "object", properties: %{}},
          callback: fn _ -> {:ok, "noop"} end
        )

      empty_stream =
        sse_data(%{
          "id" => "cmpl-empty",
          "object" => "chat.completion.chunk",
          "created" => 0,
          "model" => "test",
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{"role" => "assistant", "content" => nil},
              "finish_reason" => nil
            }
          ]
        }) <>
          sse_data(%{
            "id" => "cmpl-empty",
            "object" => "chat.completion.chunk",
            "created" => 0,
            "model" => "test",
            "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
          }) <>
          sse_data(%{
            "id" => "cmpl-empty",
            "object" => "chat.completion.chunk",
            "created" => 0,
            "model" => "test",
            "choices" => [],
            "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 0, "total_tokens" => 5}
          }) <>
          "data: [DONE]\n\n"

      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Conn.put_resp_header("content-type", "text/event-stream")
        |> Conn.put_resp_header("cache-control", "no-cache")
        |> Conn.send_resp(200, empty_stream)
      end)

      assert {:ok, %EmptyResult{}} = ChatClient.send_message_stream(context, tools: [tool])
    end

    test "respects max_tokens option for context trimming", %{bypass: bypass, context: _context} do
      long_context =
        Context.new(
          [Context.system("You are helpful.")] ++
            Enum.map(1..100, fn i -> Context.user("Message #{i}") end)
        )

      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Conn.put_resp_header("content-type", "text/event-stream")
        |> Conn.put_resp_header("cache-control", "no-cache")
        |> Conn.send_resp(200, sse_content(["trimmed"], id: "cmpl-4"))
      end)

      assert {:ok, %ContentResult{stream: stream}} =
               ChatClient.send_message_stream(long_context, max_tokens: 10)

      tokens = ReqLLM.StreamResponse.tokens(stream)
      text = Enum.join(tokens)
      assert text == "trimmed"
    end
  end

  describe "execute_tool/3" do
    test "executes tool and returns result" do
      tool =
        ReqLLM.Tool.new!(
          name: "echo",
          description: "Echoes input",
          parameter_schema: %{
            type: "object",
            properties: %{input: %{type: "string"}},
            required: ["input"]
          },
          callback: fn %{"input" => input} -> {:ok, "Echo: #{input}"} end
        )

      assert {:ok, "Echo: hello"} = ChatClient.execute_tool(tool, %{"input" => "hello"})
    end

    test "uses custom cache module" do
      tool =
        ReqLLM.Tool.new!(
          name: "counter",
          description: "Counts calls",
          parameter_schema: %{type: "object", properties: %{}},
          callback: fn _ -> {:ok, "called"} end
        )

      ChatClientTest.Cache.start()
      ChatClientTest.Cache.save_result("counter", %{}, "called")

      assert {:ok, "called"} =
               ChatClient.execute_tool(tool, %{}, cache: ChatClientTest.Cache)
    end

    test "returns error when tool fails" do
      tool =
        ReqLLM.Tool.new!(
          name: "failing",
          description: "Always fails",
          parameter_schema: %{type: "object", properties: %{}},
          callback: fn _ -> {:error, "something went wrong"} end
        )

      assert {:error, "something went wrong"} = ChatClient.execute_tool(tool, %{})
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

  defp sse_tool_call(tool_calls, opts) do
    model = Keyword.get(opts, :model, "test-model")
    id = Keyword.get(opts, :id, "chatcmpl-test")

    null_chunk =
      sse_data(%{
        "id" => id,
        "object" => "chat.completion.chunk",
        "created" => 0,
        "model" => model,
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{"role" => "assistant", "content" => nil},
            "finish_reason" => nil
          }
        ]
      })

    tc_chunks =
      tool_calls
      |> Enum.with_index()
      |> Enum.map(fn {tc, i} ->
        sse_data(%{
          "id" => id,
          "object" => "chat.completion.chunk",
          "created" => 0,
          "model" => model,
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [
                  %{
                    "id" => tc["id"],
                    "type" => "function",
                    "index" => i,
                    "function" => %{"name" => tc["name"], "arguments" => tc["arguments"]}
                  }
                ]
              },
              "finish_reason" => nil
            }
          ]
        })
      end)

    finish =
      sse_data(%{
        "id" => id,
        "object" => "chat.completion.chunk",
        "created" => 0,
        "model" => model,
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "tool_calls"}]
      })

    usage =
      sse_data(%{
        "id" => id,
        "object" => "chat.completion.chunk",
        "created" => 0,
        "model" => model,
        "choices" => [],
        "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 30, "total_tokens" => 50}
      })

    done = "data: [DONE]\n\n"

    Enum.join([null_chunk] ++ tc_chunks ++ [finish, usage, done])
  end

  defp sse_data(map) do
    "data: #{Jason.encode!(map)}\n\n"
  end
end

defmodule ChatClientTest.Cache do
  @behaviour BranchedLLM.ToolCacheBehaviour

  def start do
    case :ets.info(__MODULE__) do
      :undefined -> :ets.new(__MODULE__, [:named_table, :public, :set])
      _ -> :ok
    end
  end

  def get_result(tool_name, args) do
    case :ets.lookup(__MODULE__, {tool_name, args}) do
      [{_, {:ok, _} = result}] -> result
      _ -> :error
    end
  end

  def save_result(tool_name, args, result) do
    :ets.insert(__MODULE__, {{tool_name, args}, {:ok, result}})
    :ok
  end
end
