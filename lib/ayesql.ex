defmodule AyeSQL do
  @moduledoc """
  > **Aye** _/ʌɪ/_ _exclamation (archaic dialect)_: said to express assent; yes.

  _AyeSQL_ is a small Elixir library for using raw SQL.

  ## Overview

  Inspired on Clojure library [Yesql](https://github.com/krisajenkins/yesql),
  _AyeSQL_ tries to find a middle ground between those two approaches by:

  - Keeping the SQL in SQL files.
  - Generating Elixir functions for every query.
  - Having mandatory and optional named parameters.
  - Allowing query composability with ease.

  Using the previous query, we would create a SQL file with the following
  contents:

  ```sql
  -- name: get_day_interval
  -- This query do not have docs, so it's private.
  SELECT datetime::date AS date
    FROM generate_series(
          current_date - :days::interval, -- Named parameter :days
          current_date - interval '1 day',
          interval '1 day'
        );

  -- name: get_avg_clicks
  -- docs: Gets average click count.
      WITH computed_dates AS ( :get_day_interval ) -- Composing with another query
    SELECT dates.date AS day, count(clicks.id) AS count
      FROM computed_date AS dates
          LEFT JOIN clicks AS clicks ON date(clicks.inserted_at) = dates.date
    WHERE clicks.link_id = :link_id -- Named parameter :link_id
  GROUP BY dates.date
  ORDER BY dates.date;
  ```

  In Elixir we would load all the queries in this file by creating the following
  module:

  ```elixir
  defmodule Queries do
    use AyeSQL, repo: MyRepo

    defqueries("queries.sql") # File name with relative path to SQL file.
  end
  ```

  or using the macro `defqueries/3`:

  ```elixir
  import AyeSQL, only: [defqueries: 3]

  defqueries(Queries, "queries.sql", repo: MyRepo)
  ```

  Both approaches will create a module called `Queries` with all the queries
  defined in `"queries.sql"`.

  And then we could execute the query as follows:

  ```elixir
  iex> params = [
  ...>   link_id: 42,
  ...>   days: %Postgrex.Interval{secs: 864_000} # 10 days
  ...> ]
  iex> Queries.get_avg_clicks(params, run?: true)
  {:ok,
    [
      %{day: ..., count: ...},
      ...
    ]
  }
  ```
  """
  alias AyeSQL.Query
  alias AyeSQL.Parser

  @doc """
  Uses `AyeSQL` for loading queries.

  The available options are:

  - `runner`: module handling the query.

  Any other option will be passed to the runner.
  """
  defmacro __using__(options) do
    {db_runner, db_options} = Keyword.pop(options, :runner, AyeSQL.Runner.Ecto)

    quote do
      import AyeSQL, only: [defqueries: 1]

      @__db_runner__ unquote(db_runner)
      @__db_options__ unquote(db_options)

      @doc """
      Runs the `query`. On error, fails.
      """
      @spec run!(Query.t()) :: term() | no_return()
      @spec run!(Query.t(), keyword()) :: term() | no_return()
      def run!(query, options \\ [])

      def run!(query, options) do
        case run(query, options) do
          {:ok, result} ->
            result

          {:error, reason} ->
            raise RuntimeError, message: reason
        end
      end

      @doc """
      Runs the `query`.
      """
      @spec run(Query.t()) :: {:ok, term()} | {:error, term()}
      @spec run(Query.t(), keyword()) :: {:ok, term()} | {:error, term()}
      def run(query, options \\ [])

      def run(%Query{} = query, options) do
        db_options = Keyword.merge(@__db_options__, options)

        AyeSQL.run(@__db_runner__, query, db_options)
      end

      ########################
      # Helpers for inspection

      @doc false
      @spec __db_runner__() :: module()
      def __db_runner__, do: @__db_runner__

      @doc false
      @spec __db_options__() :: term()
      def __db_options__, do: @__db_options__
    end
  end

  # Runs a `stmt` with some `args` in an `app`.
  @doc false
  @spec run(module(), Query.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def run(module, query, options)

  def run(module, %Query{} = query, options) do
    module.run(query, options)
  end

  @doc """
  Macro to load queries from a `file`.

  Let's say we have the file `my_queries.sql` with the following contents:

  ```sql
  -- name: get_user
  -- docs: Gets user by username
  SELECT *
    FROM users
   WHERE username = :username;
  ```

  We can load our queries to Elixir using the macro `defqueries/1` as follows:

  ```
  defmodule Queries do
    use AyeSQL, repo: MyRepo

    defqueries("my_queries.sql")
  end
  ```

  We can now do the following to get the SQL and the ordered arguments:

  ```
  iex(1)> Queries.get_user!(%{username: "some_user"})
  {"SELECT * FROM user WHERE username = $1", ["some_user"]}
  ```

  If we would like to execute the previous query directly, the we could do the
  following:

  ```
  iex(1)> Queries.get_user!(%{username: "some_user"}, run?: true)
  %Postgrex.Result{...}
  ```

  We can also run the query by composing it with the `Queries.run/1` function
  generated in the module e.g:
  ```
  iex(1)> %{username: "some_user"} |> Queries.get_user!() |> Queries.run!()
  %Postgrex.Result{...}
  ```
  """
  defmacro defqueries(relative) do
    dirname = Path.dirname(__CALLER__.file)
    filename = Path.expand("#{dirname}/#{relative}")

    [
      quote(do: @external_resource(unquote(filename))),
      Parser.create_queries(filename)
    ]
  end

  @doc """
  Macro to load queries from a `file` and create a module for them.

  Same as `defqueries/1`, but creates a module e.g:

  ```
  use AyeSQL, repo: MyRepo

  defqueries(Queries, "my_queries.sql")
  ```

  This will generate the module `Queries` and it'll contain all the SQL
  statements included in `"sql/my_queries.sql"`.
  """
  defmacro defqueries(module, relative, options) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        This module defines functions for queries in `#{unquote(relative)}`
        """
        use AyeSQL, unquote(options)

        defqueries(unquote(relative))
      end
    end
  end
end
