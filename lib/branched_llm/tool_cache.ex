defmodule BranchedLLM.ToolCache do
  @moduledoc """
  Database-backed caching for tool execution results.

  This module provides a generic Ecto-based cache for tool results.
  The Ecto repo module must be configured via:

      config :branched_llm, BranchedLLM.ToolCache,
        repo: MyApp.Repo

  Or by implementing the `BranchedLLM.ToolCacheBehaviour` behaviour with your own storage backend.

  ## Schema

  The underlying `tool_results` table has the following columns:

    * `tool_name` (string) - The name of the tool
    * `args` (map/JSONB) - The arguments passed to the tool
    * `result` (text) - The cached result
    * `inserted_at`, `updated_at` - Timestamps

  ## Migration

  To create the required table, add a migration in your host application:

      def change do
        create table(:tool_results) do
          add :tool_name, :string, null: false
          add :args, :map, null: false
          add :result, :text, null: false
          timestamps()
        end

        create index(:tool_results, [:tool_name, :args])
      end

  """

  import Ecto.Query

  @doc """
  Retrieves a cached tool result for the given tool name and arguments.

  Returns `{:ok, result}` if found, `:error` otherwise.
  """
  @spec get_result(String.t(), map()) :: {:ok, String.t()} | :error
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

  @doc """
  Saves a tool result to the cache.

  Returns `:ok` on success.
  """
  @spec save_result(String.t(), map(), String.t()) :: :ok
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
    # Ensure keys are strings for JSONB compatibility
    Map.new(args, fn {k, v} -> {to_string(k), v} end)
  end

  defp normalize_args(args) do
    # Wrap non-map args in a map for JSONB compatibility
    %{"args" => args}
  end
end
