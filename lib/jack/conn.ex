defmodule Jack.Conn do
  @moduledoc """
  The Jack connection.

  This module defines a `Jack.Conn` struct and the main functions
  for working with Jack connections.

  ## Input fields

  These fields contain the input information:

    * `input` - the user given input params

  ## Output fields

  These fields contain output information:

    * `output` - the output value after processing the jack, `nil` by default.
    * `status` - the output status, starts as :none, you need to set it as :ok
      for a good output and anything else for bad (by default use :error as an
      standartization)

  ## Connection fields

    * `assigns` - shared user data as a map
    * `halted` - the boolean status on whether the pipeline was halted
    * `state` - the connection state

  The connection state is used to track the connection lifecycle. It starts
  as `:unset` but is changed to `:set` (via `Jack.Conn.output/3`). Its
  final result is `:sent` depending on the output model.

  ## Private fields

  These fields are reserved for libraries/framework usage.

    * `private` - shared library data as a map
  """

  @type halted          :: boolean
  @type output          :: any
  @type params          :: %{atom => any} | %{}
  @type state           :: :unset | :set | :sent
  @type status          :: atom

  @type t :: %__MODULE__{
              assigns:         assigns,
              input:           params,
              output:          output,
              private:         assigns,
              state:           state,
              status:          status}

  defstruct assigns:         %{},
            input:           %{},
            halted:          false,
            output:          nil,
            private:         %{},
            state:           :unset,
            status:          :none

  defmodule NotSentError do
    defexception message: "an output was neither set nor sent from the connection"

    @moduledoc """
    Error raised when no output is sent in a request
    """
  end

  defmodule AlreadySentError do
    defexception message: "the output was already sent"

    @moduledoc """
    Error raised when trying to modify or send an already sent output
    """
  end

  alias Jack.Conn

  @doc """
  Assigns a value to a key in the connection

  ## Examples

      iex> conn.assigns[:hello]
      nil
      iex> conn = assign(conn, :hello, :world)
      iex> conn.assigns[:hello]
      :world

  """
  @spec assign(t, atom, term) :: t
  def assign(%Conn{assigns: assigns} = conn, key, value) when is_atom(key) do
    %{conn | assigns: Map.put(assigns, key, value)}
  end

  @doc """
  Starts a task to assign a value to a key in the connection.

  `await_assign/2` can be used to wait for the async task to complete and
  retrieve the resulting value.

  Behind the scenes, it uses `Task.async/1`.

  ## Examples

      iex> conn.assigns[:hello]
      nil
      iex> conn = async_assign(conn, :hello, fn -> :world end)
      iex> conn.assigns[:hello]
      %Task{...}

  """
  @spec async_assign(t, atom, (() -> term)) :: t
  def async_assign(%Conn{} = conn, key, fun) when is_atom(key) and is_function(fun, 0) do
    assign(conn, key, Task.async(fun))
  end

  @doc """
  Awaits the completion of an async assign.

  Returns a connection with the value resulting from the async assignment placed
  under `key` in the `:assigns` field.

  Behind the scenes, it uses `Task.await/2`.

  ## Examples

      iex> conn.assigns[:hello]
      nil
      iex> conn = async_assign(conn, :hello, fn -> :world end)
      iex> conn = await_assign(conn, :hello) # blocks until `conn.assigns[:hello]` is available
      iex> conn.assigns[:hello]
      :world

  """
  @spec await_assign(t, atom, timeout) :: t
  def await_assign(%Conn{} = conn, key, timeout \\ 5000) when is_atom(key) do
    task = Map.fetch!(conn.assigns, key)
    assign(conn, key, Task.await(task, timeout))
  end

  @doc """
  Assigns a new **private** key and value in the connection.

  This storage is meant to be used by libraries and frameworks to avoid writing
  to the user storage (the `:assigns` field). It is recommended for
  libraries/frameworks to prefix the keys with the library name.

  For example, if some jack needs to store a `:hello` key, it
  should do so as `:jack_hello`:

      iex> conn.private[:jack_hello]
      nil
      iex> conn = put_private(conn, :jack_hello, :world)
      iex> conn.private[:jack_hello]
      :world

  """
  @spec put_private(t, atom, term) :: t
  def put_private(%Conn{private: private} = conn, key, value) when is_atom(key) do
    %{conn | private: Map.put(private, key, value)}
  end

  @doc """
  Stores the given status code in the connection.

  The status code can be `nil`, an integer or an atom. The list of allowed
  atoms is available in `Jack.Conn.Status`.

  Raises a `Jack.Conn.AlreadySentError` if the connection has already been
  `:sent`.
  """
  @spec put_status(t, status) :: t
  def put_status(%Conn{state: :sent}, _status),
    do: raise AlreadySentError
  def put_status(%Conn{} = conn, nil),
    do: %{conn | status: nil}
  def put_status(%Conn{} = conn, status),
    do: %{conn | status: Jack.Conn.Status.code(status)}

  @doc """
  Sends an output to the client.

  It expects the connection state to be `:set`, otherwise raises an
  `ArgumentError` for `:unset` connections or a `Jack.Conn.AlreadySentError` for
  already `:sent` connections.

  At the end sets the connection state to `:sent`.
  """
  @spec send_output(t) :: t | no_return
  def send_output(conn)

  def send_output(%Conn{state: :unset}) do
    raise ArgumentError, "cannot send an output that was not set"
  end

  def send_output(%Conn{state: :set} = conn) do
    %{conn | state: :sent}
  end

  def send_output(%Conn{}) do
    raise AlreadySentError
  end

  @doc """
  Sends an output with the given status and output.

  See `send_output/1` for more information.
  """
  @spec send_output(t, status, output) :: t | no_return
  def send_output(%Conn{} = conn, status, output) do
    conn |> output(status, output) |> send_output()
  end

  @doc """
  Sets the output to the given `status` and `output`.

  It sets the connection state to `:set` (if not already `:set`)
  and raises `Jack.Conn.AlreadySentError` if it was already `:sent`.
  """
  @spec output(t, status, output) :: t
  def output(%Conn{state: :sent}, _status, _output) do
    raise AlreadySentError
  end
  def output(%Conn{} = conn, status, output) do
    %{conn | status: Jack.Conn.Status.code(status), output: output, state: :set}
  end

  @doc """
  Halts the Jack pipeline by preventing further jacks downstream from being
  invoked. See the docs for `Jack.Builder` for more information on halting a
  jack pipeline.
  """
  @spec halt(t) :: t
  def halt(%Conn{} = conn) do
    %{conn | halted: true}
  end
end

