[
  # ReqLLM references LLMDB.Model.t/0 which is a transitive dependency.
  # :llm_db is included in plt_add_apps so Dialyzer can resolve the type,
  # but the error originates in req_llm (a dependency), not in our code.
  # If the PLT still cannot resolve it (e.g., after a dependency upgrade),
  # re-enable this ignore entry.
  # {"lib/req_llm/stream_response.ex", :unknown_type}
]
