-module(plainwire_config).
-export([port/0, db_path/0, cookie_secure/0]).

port() ->
    case os:getenv("PORT") of
        false -> 8080;
        V -> list_to_integer(V)
    end.

db_path() ->
    case os:getenv("PLAINWIRE_DB") of
        false -> filename:join(["data", "plainwire.sqlite3"]);
        V -> V
    end.

cookie_secure() ->
    case os:getenv("COOKIE_SECURE") of
        "1" -> true;
        "true" -> true;
        _ -> false
    end.
