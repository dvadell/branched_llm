if Code.ensure_loaded?(Ecto) do
  defmodule BranchedLLM.ToolCache.Ecto do
    @moduledoc """
    Database-backed caching for tool execution results using Ecto.
    """
    @behaviour BranchedLLM.ToolCacheBehaviour

    import Ecto.Query

    @impl true
    def get_result(tool_name, args) do
      repo = get_repo()

      if is_nil(repo) do
        :error
      else
        normalized_args = normalize_args(args)

        repo.one(
          from(tr in tool_results_schema(repo),
            where: tr.tool_name == ^tool_name and tr.args == ^normalized_args,
            order_by: [desc: tr.inserted_at],
            limit: 1,
            select: tr.result
          )
        )
        |> case do
          nil -> :error
          result -> {:ok, result}
        end
      end
    end

    @impl true
    def save_result(tool_name, args, result) do
      repo = get_repo()

      if is_nil(repo) do
        :ok
      else
        normalized_args = normalize_args(args)

        repo.insert_all(tool_results_schema(repo), [
          %{
            tool_name: tool_name,
            args: normalized_args,
            result: result,
            inserted_at: NaiveDateTime.utc_now(),
            updated_at: NaiveDateTime.utc_now()
          }
        ])

        :ok
      end
    end

    defp get_repo do
      Application.get_env(:branched_llm, BranchedLLM.ToolCache, [])
      |> Keyword.get(:repo)
    end

    defp tool_results_schema(repo) do
      Module.concat(repo, ToolResult)
    end

    defp normalize_args(args) when is_map(args) do
      Map.new(args, fn {k, v} -> {to_string(k), v} end)
    end

    defp normalize_args(args) do
      %{"args" => args}
    end
  end
end
