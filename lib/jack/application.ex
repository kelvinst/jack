defmodule Jack.Application do
  # See http://elixir-lang.org/docs/stable/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @doc false
  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    # Define workers and child supervisors to be supervised
    children = [
      # Starts a worker by calling: Jack.Worker.start_link(arg1, arg2, arg3)
      # worker(Jack.Upload, [])
    ]

    # See http://elixir-lang.org/docs/stable/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Jack.Supervisor]

    # TODO - implement this translator
    # Logger.add_translator {Jack.Adapters.Translator, :translate}
    Supervisor.start_link(children, opts)
  end
end
