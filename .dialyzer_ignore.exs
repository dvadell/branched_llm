[
  # ReqLLM references LLMDB.Model.t/0 which is a transitive dependency
  # not included in this project's Dialyzer PLT.
  # The error is in req_llm ( the dependency ) not in our code!
  {"lib/req_llm/stream_response.ex", :unknown_type}
]
