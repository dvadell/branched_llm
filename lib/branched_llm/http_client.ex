# credo:disable-for-this-file Credo.Check.Extra.NoDirectThirdPartyCalls
defmodule BranchedLLM.HttpClient do
  @moduledoc false

  def new(opts \\ []) do
    Req.new(opts)
  end

  def get(request, url: url) do
    request = maybe_attach_telemetry(request)
    request = maybe_notify(request)

    :telemetry.span(
      [:branched_llm, :http, :request],
      %{method: :get, url: url},
      fn ->
        {Req.get(request, url: url), %{}}
      end
    )
  end

  defp maybe_attach_telemetry(req) do
    if Code.ensure_loaded?(OpentelemetryReq) do
      OpentelemetryReq.attach(req, no_path_params: true)
    else
      req
    end
  end

  defp maybe_notify(request) do
    case Application.get_env(:branched_llm, :on_request) do
      nil -> request
      fun -> fun.(request)
    end
  end
end
