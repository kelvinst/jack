defmodule Jack.Builder do
  @moduledoc """
  Conveniences for building jacks.

  This module can be `use`-d into a module in order to build
  a jack pipeline:

      defmodule MyApp do
        use Jack.Builder

        jack Jack.Logger
        jack :hello, upper: true

        # A function from another module can be jackged too, provided it's
        # imported into the current module first.
        import AnotherModule, only: [interesting_jack: 2]
        jack :interesting_jack

        def hello(conn, opts) do
          body = if opts[:upper], do: "WORLD", else: "world"
          send_resp(conn, 200, body)
        end
      end

  Multiple jacks can be defined with the `jack/2` macro, forming a pipeline.
  The jacks in the pipeline will be executed in the order they've been added
  through the `jack/2` macro. In the example above, `Jack.Logger` will be
  called first and then the `:hello` function jack will be called on the
  resulting connection.

  `Jack.Builder` also imports the `Jack.Conn` module, making functions like
  `send_resp/3` available.

  ## Options

  When used, the following options are accepted by `Jack.Builder`:

    * `:log_on_halt` - accepts the level to log whenever the request is halted

  ## Jack behaviour

  Internally, `Jack.Builder` implements the `Jack` behaviour, which means both
  the `init/1` and `call/2` functions are defined.

  By implementing the Jack API, `Jack.Builder` guarantees this module is a jack
  and can be handed to a web server or used as part of another pipeline.

  ## Overriding the default Jack API functions

  Both the `init/1` and `call/2` functions defined by `Jack.Builder` can be
  manually overridden. For example, the `init/1` function provided by
  `Jack.Builder` returns the options that it receives as an argument, but its
  behaviour can be customized:

      defmodule JackWithCustomOptions do
        use Jack.Builder
        jack Jack.Logger

        def init(opts) do
          opts
        end
      end

  The `call/2` function that `Jack.Builder` provides is used internally to
  execute all the jacks listed using the `jack` macro, so overriding the
  `call/2` function generally implies using `super` in order to still call the
  jack chain:

      defmodule JackWithCustomCall do
        use Jack.Builder
        jack Jack.Logger
        jack Jack.Head

        def call(conn, opts) do
          super(conn, opts) # calls Jack.Logger and Jack.Head
          assign(conn, :called_all_jacks, true)
        end
      end


  ## Halting a jack pipeline

  A jack pipeline can be halted with `Jack.Conn.halt/1`. The builder will
  prevent further jacks downstream from being invoked and return the current
  connection. In the following example, the `Jack.Logger` jack never gets
  called:

      defmodule JackUsingHalt do
        use Jack.Builder

        jack :stopper
        jack Jack.Logger

        def stopper(conn, _opts) do
          halt(conn)
        end
      end
  """

  @type jack :: module | atom

  @doc false
  defmacro __using__(opts) do
    quote do
      @behaviour Jack
      @jack_builder_opts unquote(opts)

      def init(opts) do
        opts
      end

      def call(conn, opts) do
        jack_builder_call(conn, opts)
      end

      defoverridable [init: 1, call: 2]

      import Jack.Conn
      import Jack.Builder, only: [jack: 1, jack: 2]

      Module.register_attribute(__MODULE__, :jacks, accumulate: true)
      @before_compile Jack.Builder
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    jacks        = Module.get_attribute(env.module, :jacks)
    builder_opts = Module.get_attribute(env.module, :jack_builder_opts)

    {conn, body} = Jack.Builder.compile(env, jacks, builder_opts)

    quote do
      defp jack_builder_call(unquote(conn), _), do: unquote(body)
    end
  end

  @doc """
  A macro that stores a new jack. `opts` will be passed unchanged to the new
  jack.

  This macro doesn't add any guards when adding the new jack to the pipeline;
  for more information about adding jacks with guards see `compile/1`.

  ## Examples

      jack Jack.Logger               # jack module
      jack :foo, some_options: true  # jack function

  """
  defmacro jack(jack, opts \\ []) do
    quote do
      @jacks {unquote(jack), unquote(opts), true}
    end
  end

  @doc """
  Compiles a jack pipeline.

  Each element of the jack pipeline (according to the type signature of this
  function) has the form:

      {jack_name, options, guards}

  Note that this function expects a reversed pipeline (with the last jack that
  has to be called coming first in the pipeline).

  The function returns a tuple with the first element being a quoted reference
  to the connection and the second element being the compiled quoted pipeline.

  ## Examples

      Jack.Builder.compile(env, [
        {Jack.Logger, [], true}, # no guards, as added by the Jack.Builder.jack/2 macro
        {Jack.Head, [], quote(do: a when is_binary(a))}
      ], [])

  """
  @spec compile(Macro.Env.t, [{jack, Jack.opts, Macro.t}], Keyword.t) :: {Macro.t, Macro.t}
  def compile(env, pipeline, builder_opts) do
    conn = quote do: conn
    {conn, Enum.reduce(pipeline, conn, &quote_jack(init_jack(&1), &2, env, builder_opts))}
  end

  # Initializes the options of a jack at compile time.
  defp init_jack({jack, opts, guards}) do
    case Atom.to_char_list(jack) do
      ~c"Elixir." ++ _ -> init_module_jack(jack, opts, guards)
      _                -> init_fun_jack(jack, opts, guards)
    end
  end

  defp init_module_jack(jack, opts, guards) do
    initialized_opts = jack.init(opts)

    if function_exported?(jack, :call, 2) do
      {:module, jack, initialized_opts, guards}
    else
      raise ArgumentError, message: "#{inspect jack} jack must implement call/2"
    end
  end

  defp init_fun_jack(jack, opts, guards) do
    {:function, jack, opts, guards}
  end

  # `acc` is a series of nested jack calls in the form of
  # jack3(jack2(jack1(conn))). `quote_jack` wraps a new jack around that series
  # of calls.
  defp quote_jack({jack_type, jack, opts, guards}, acc, env, builder_opts) do
    call = quote_jack_call(jack_type, jack, opts)

    error_message = case jack_type do
      :module   -> "expected #{inspect jack}.call/2 to return a Jack.Conn"
      :function -> "expected #{jack}/2 to return a Jack.Conn"
    end <> ", all jacks must receive a connection (conn) and return a connection"

    {fun, meta, [arg, [do: clauses]]} =
      quote do
        case unquote(compile_guards(call, guards)) do
          %Jack.Conn{halted: true} = conn ->
            unquote(log_halt(jack_type, jack, env, builder_opts))
            conn
          %Jack.Conn{} = conn ->
            unquote(acc)
          _ ->
            raise unquote(error_message)
        end
      end

    generated? = :erlang.system_info(:otp_release) >= '19'

    clauses =
      Enum.map(clauses, fn {:->, meta, args} ->
        if generated? do
          {:->, [generated: true] ++ meta, args}
        else
          {:->, Keyword.put(meta, :line, -1), args}
        end
      end)

    {fun, meta, [arg, [do: clauses]]}
  end

  defp quote_jack_call(:function, jack, opts) do
    quote do: unquote(jack)(conn, unquote(Macro.escape(opts)))
  end

  defp quote_jack_call(:module, jack, opts) do
    quote do: unquote(jack).call(conn, unquote(Macro.escape(opts)))
  end

  defp compile_guards(call, true) do
    call
  end

  defp compile_guards(call, guards) do
    quote do
      case true do
        true when unquote(guards) -> unquote(call)
        true -> conn
      end
    end
  end

  defp log_halt(jack_type, jack, env, builder_opts) do
    if level = builder_opts[:log_on_halt] do
      message = case jack_type do
        :module   -> "#{inspect env.module} halted in #{inspect jack}.call/2"
        :function -> "#{inspect env.module} halted in #{inspect jack}/2"
      end

      quote do
        require Logger
        # Matching, to make Dialyzer happy on code executing Jack.Builder.compile/3
        _ = Logger.unquote(level)(unquote(message))
      end
    else
      nil
    end
  end
end
