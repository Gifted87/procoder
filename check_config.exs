# check_config.exs
IO.inspect(Application.get_env(:procoder, ProCoder.SessionManager), label: "SessionManager Config")
