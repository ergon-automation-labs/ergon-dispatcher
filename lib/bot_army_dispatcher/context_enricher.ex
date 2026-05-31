defmodule BotArmyDispatcher.ContextEnricher do
  @moduledoc """
  Enriches decomposition patterns with relevant context from knowledge graphs and internal docs.

  Fetches background context (similar goals, related docs, available resources) to improve
  decomposition quality. Called when suggesting patterns from Learning service.

  ## Sources

  - Graphify cache: Past similar goals, related modules, dependencies
  - Internal docs: Available runbooks, guides, API documentation
  """

  require Logger
  alias BotArmyRuntime.NATS.Connection, as: NATSConnection

  @bridge_graph_query_timeout_ms 8000
  @max_context_results 5

  @doc """
  Enriches a decomposition pattern with relevant context from knowledge graphs.

  Returns the pattern map with added 'context' field containing relevant background info.

  ## Arguments
    - `pattern` - Map with 'subtasks', 'signature', etc. from Learning service
    - `goal` - Current goal text for context matching
    - `repo_path` - Optional path to search knowledge graph (e.g., repo dir)

  ## Returns
    - Pattern map with 'context' field added (or original if context unavailable)
    - Context includes: related_goals, available_resources, similar_patterns
  """
  def enrich_pattern(pattern, goal, repo_path \\ nil)
      when is_map(pattern) and is_binary(goal) do
    case query_context(goal, repo_path) do
      {:ok, context} ->
        Logger.debug("[ContextEnricher] Enriched pattern with context",
          signature: pattern["signature"],
          context_sources: map_size(context)
        )

        Map.put(pattern, "context", context)

      {:error, reason} ->
        Logger.warning("[ContextEnricher] Failed to enrich with context",
          goal: String.slice(goal, 0, 50),
          reason: inspect(reason)
        )

        # Return pattern without context if enrichment fails
        pattern
    end
  end

  # ============================================================================
  # Context Queries
  # ============================================================================

  defp query_context(goal, repo_path) do
    context = %{}

    # Query graphify for related patterns and resources
    context =
      case query_graphify(goal, repo_path) do
        {:ok, graph_context} ->
          Map.put(context, "graph", graph_context)

        {:error, _} ->
          context
      end

    # Query internal docs for runbooks/guides
    context =
      case query_internal_docs(goal) do
        {:ok, docs_context} ->
          Map.put(context, "docs", docs_context)

        {:error, _} ->
          context
      end

    if map_size(context) > 0 do
      {:ok, context}
    else
      {:error, :no_context_available}
    end
  end

  defp query_graphify(goal, repo_path) do
    repo_path = repo_path || Path.expand("~") <> "/code/elixir_bots"

    payload =
      Jason.encode!(%{
        "repo_path" => repo_path,
        "query" => String.slice(goal, 0, 100)
      })

    case query_nats_service("bridge.graph.query", payload, @bridge_graph_query_timeout_ms) do
      {:ok, response} ->
        case Jason.decode(response) do
          {:ok, %{"graph" => graph, "cached_at" => _}} ->
            # Extract high-level info: modules, functions, related patterns
            {
              :ok,
              %{
                "available_repos" => extract_repos(graph),
                "common_patterns" => extract_patterns(graph),
                "relevant_modules" => extract_modules(goal, graph)
              }
            }

          {:ok, %{"error" => error}} ->
            {:error, error}

          _ ->
            {:error, :invalid_response}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp query_internal_docs(goal) do
    payload =
      Jason.encode!(%{
        "query" => String.slice(goal, 0, 100),
        "limit" => @max_context_results
      })

    case query_nats_service(
           "bridge.internal_docs.query",
           payload,
           5000
         ) do
      {:ok, response} ->
        case Jason.decode(response) do
          {:ok, %{"data" => docs}} ->
            {
              :ok,
              %{
                "runbooks" => extract_runbooks(docs),
                "guides" => extract_guides(docs)
              }
            }

          {:ok, %{"error" => error}} ->
            {:error, error}

          _ ->
            {:error, :invalid_response}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # NATS Query Helper
  # ============================================================================

  defp query_nats_service(subject, payload, timeout_ms) do
    case NATSConnection.get_connection() do
      {:ok, conn} ->
        case Gnat.request(conn, subject, payload, receive_timeout: timeout_ms) do
          {:ok, %{body: response}} ->
            {:ok, response}

          {:error, :timeout} ->
            {:error, :timeout}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ -> {:error, :connection_failed}
  end

  # ============================================================================
  # Context Extraction Helpers
  # ============================================================================

  defp extract_repos(graph) when is_map(graph) do
    # Extract list of repo names from graph metadata
    case Map.get(graph, "repos") do
      repos when is_list(repos) ->
        repos |> Enum.map(&Map.get(&1, "name")) |> Enum.uniq()

      _ ->
        []
    end
  end

  defp extract_repos(_), do: []

  defp extract_patterns(graph) when is_map(graph) do
    # Extract common execution patterns
    case Map.get(graph, "patterns") do
      patterns when is_list(patterns) ->
        patterns
        |> Enum.take(@max_context_results)
        |> Enum.map(&Map.get(&1, "name"))

      _ ->
        []
    end
  end

  defp extract_patterns(_), do: []

  defp extract_modules(goal, graph) when is_map(graph) do
    goal_words = String.downcase(goal) |> String.split()

    case Map.get(graph, "modules") do
      modules when is_list(modules) ->
        modules
        |> Enum.filter(fn mod ->
          mod_name = String.downcase(Map.get(mod, "name", ""))
          Enum.any?(goal_words, fn word -> String.contains?(mod_name, word) end)
        end)
        |> Enum.take(@max_context_results)
        |> Enum.map(&Map.get(&1, "name"))

      _ ->
        []
    end
  end

  defp extract_modules(_goal, _graph), do: []

  defp extract_runbooks(docs) when is_list(docs) do
    docs
    |> Enum.filter(&runbook?/1)
    |> Enum.map(&doc_summary/1)
    |> Enum.take(@max_context_results)
  end

  defp extract_runbooks(_), do: []

  defp extract_guides(docs) when is_list(docs) do
    docs
    |> Enum.filter(&guide?/1)
    |> Enum.map(&doc_summary/1)
    |> Enum.take(@max_context_results)
  end

  defp extract_guides(_), do: []

  defp runbook?(doc) when is_map(doc) do
    path = Map.get(doc, "path", "")
    String.contains?(path, "runbook")
  end

  defp runbook?(_), do: false

  defp guide?(doc) when is_map(doc) do
    path = Map.get(doc, "path", "")
    String.contains?(path, ["guide", "docs"]) and not String.contains?(path, "runbook")
  end

  defp guide?(_), do: false

  defp doc_summary(doc) when is_map(doc) do
    %{
      "title" => Map.get(doc, "title", ""),
      "path" => Map.get(doc, "path", ""),
      "snippet" => Map.get(doc, "content", "") |> String.slice(0, 200)
    }
  end

  defp doc_summary(doc), do: doc
end
