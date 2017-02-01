defmodule Jack do
	@moduledoc """
  The jack specification.

  First of all, I want to thank all the work of plug team, because this is
  nothing but a copy of its main plugable feature but for simpler purposes (not
  for web requests/responses).

  There are two kind of jacks: function jacks and module jacks.

  #### Function jacks

  A function jack is any function that receives a connection and a set of
  options and returns a connection. Its type signature must be:

      (Jack.Conn.t, Jack.opts) :: Jack.Conn.t

  #### Module jacks

  A module jack is an extension of the function jack. It is a module that must
  export:

    * a `call/2` function with the signature defined above
    * an `init/1` function which takes a set of options and initializes it.

  The result returned by `init/1` is passed as second argument to `call/2`. Note
  that `init/1` may be called during compilation and as such it must not return
  pids, ports or values that are not specific to the runtime.

  The API expected by a module jack is defined as a behaviour by the
  `Jack` module (this module).

  ## Examples

  Here's an example of a function jack:

      def current_user_jack(conn, opts) do
        conn |> Jack.Conn.assign(:current_user, opts[:current_user])
      end

  Here's an example of a module jack:

      defmodule CurrentUserJack do
        import Jack.Conn

        def init(opts) do
          opts[:current_user]
        end

        def call(conn, current_user) do
          conn |> assign(:current_user, current_user)
        end
      end

  ## The Jack pipeline

  The `Jack.Builder` module provides conveniences for building jack
  pipelines.
  """

  @type opts :: binary | tuple | atom | integer | float | [opts] | %{opts => opts}

  @callback init(opts) :: opts
  @callback call(Jack.Conn.t, opts) :: Jack.Conn.t
end
