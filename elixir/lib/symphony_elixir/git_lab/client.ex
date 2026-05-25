defmodule SymphonyElixir.GitLab.Client do
  @moduledoc "Thin GitLab REST client for polling and mutating issues."
  alias SymphonyElixir.{Config, Linear.Issue}

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues, do: fetch_issues_by_states(Config.settings!().tracker.active_states)

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(_states) do
    project_id = Config.settings!().tracker.project_id

    case request(:get, "/projects/#{URI.encode(project_id)}/issues?state=opened&per_page=100") do
      {:ok, issues} when is_list(issues) -> {:ok, Enum.map(issues, &to_issue/1)}
      {:ok, _} -> {:error, :invalid_issues_payload}
      error -> error
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    project_id = Config.settings!().tracker.project_id

    issue_ids
    |> Enum.map(fn id -> request(:get, "/projects/#{URI.encode(project_id)}/issues/#{id}") end)
    |> Enum.reduce({:ok, []}, fn
      {:ok, raw}, {:ok, acc} when is_map(raw) -> {:ok, [to_issue(raw) | acc]}
      {:ok, _}, _ -> {:error, :invalid_issue_payload}
      {:error, reason}, _ -> {:error, reason}
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end
  end

  @spec create_note(String.t(), String.t()) :: :ok | {:error, term()}
  def create_note(issue_id, body) do
    project_id = Config.settings!().tracker.project_id

    case request(:post, "/projects/#{URI.encode(project_id)}/issues/#{issue_id}/notes", %{body: body}) do
      {:ok, %{"id" => _}} -> :ok
      {:ok, _} -> {:error, :note_create_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    project_id = Config.settings!().tracker.project_id

    with {:ok, event} <- to_state_event(state_name),
         {:ok, %{"iid" => _}} <-
           request(:put, "/projects/#{URI.encode(project_id)}/issues/#{issue_id}", %{state_event: event}) do
      :ok
    else
      {:ok, _} -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec request(atom(), String.t(), map() | nil) :: {:ok, term()} | {:error, term()}
  def request(method, path, body \\ nil) do
    tracker = Config.settings!().tracker
    endpoint = tracker.endpoint || "https://gitlab.com/api/v4"
    url = String.trim_trailing(endpoint, "/") <> path

    opts = [method: method, url: url, headers: [{"PRIVATE-TOKEN", tracker.api_key}], receive_timeout: 30_000]
    opts = if is_map(body), do: Keyword.put(opts, :json, body), else: opts

    case Req.request(opts) do
      {:ok, %{status: status, body: raw}} when status in 200..299 -> {:ok, raw}
      {:ok, %{status: status, body: raw}} -> {:error, {:http_error, status, raw}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp to_issue(raw) do
    %Issue{
      id: to_string(Map.get(raw, "iid")),
      identifier: "GL-#{Map.get(raw, "iid")}",
      title: Map.get(raw, "title"),
      description: Map.get(raw, "description"),
      state: Map.get(raw, "state"),
      url: Map.get(raw, "web_url"),
      labels: Map.get(raw, "labels", [])
    }
  end

  defp to_state_event(state_name) do
    case state_name |> String.trim() |> String.downcase() do
      "closed" -> {:ok, "close"}
      "close" -> {:ok, "close"}
      "reopen" -> {:ok, "reopen"}
      "reopened" -> {:ok, "reopen"}
      _ -> {:error, {:unsupported_gitlab_state, state_name}}
    end
  end
end
