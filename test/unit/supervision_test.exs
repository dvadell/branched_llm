defmodule BranchedLLM.SupervisionTest do
  use ExUnit.Case, async: false

  alias BranchedLLM.ChatOrchestrator
  alias Plug.Conn
  alias ReqLLM.Context

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

  describe "TaskSupervisor supervision" do
    test "a crashing caller does not take down the supervisor", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Conn.put_resp_header("content-type", "text/event-stream")
        |> Conn.put_resp_header("cache-control", "no-cache")
        |> Conn.send_resp(200, sse_content(["ok"]))
      end)

      supervisor = Process.whereis(BranchedLLM.ChatOrchestrator.TaskSupervisor)
      assert is_pid(supervisor)

      parent = self()

      caller =
        spawn(fn ->
          context = Context.new([Context.system("You are helpful."), Context.user("Hi")])

          params = %{
            llm_context: context,
            on_event: fn _ -> :ok end,
            llm_tools: [],
            chat_mod: BranchedLLM.ChatClient,
            tool_usage_counts: %{},
            branch_id: "crash-test"
          }

          {:ok, _task_pid} = ChatOrchestrator.run(params)
          send(parent, {:caller_ran, self()})
          Process.exit(self(), :boom)
        end)

      caller_ref = Process.monitor(caller)
      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :boom}, 5_000

      # The supervisor survives the caller's non-normal exit.
      assert Process.whereis(BranchedLLM.ChatOrchestrator.TaskSupervisor) == supervisor

      # Subsequent runs from another process still work end-to-end.
      ref = make_ref()

      context = Context.new([Context.system("You are helpful."), Context.user("Hi")])

      params = %{
        llm_context: context,
        on_event: fn
          {:llm_end, _id, text} -> send(parent, {ref, :end, text})
          _ -> :ok
        end,
        llm_tools: [],
        chat_mod: BranchedLLM.ChatClient,
        tool_usage_counts: %{},
        branch_id: "after-crash"
      }

      {:ok, _pid} = ChatOrchestrator.run(params)
      assert_receive {^ref, :end, "ok"}, 5_000
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
