-module(plainwire_util).
-export([
    now/0, bin/1, str/1, trim/1, lower/1, random_token/1,
    password_hash/1, verify_password/2, sanitize_username/1,
    html_preview/1
]).

now() -> erlang:system_time(second).

bin(V) when is_binary(V) -> V;
bin(V) when is_list(V) -> unicode:characters_to_binary(V);
bin(V) when is_integer(V) -> integer_to_binary(V);
bin(undefined) -> <<>>;
bin(V) -> unicode:characters_to_binary(io_lib:format("~p", [V])).

str(V) when is_list(V) -> V;
str(V) when is_binary(V) -> unicode:characters_to_list(V);
str(undefined) -> "";
str(V) -> io_lib:format("~p", [V]).

trim(V) -> string:trim(str(V)).
lower(V) -> string:lowercase(trim(V)).

random_token(Bytes) ->
    base64:encode(crypto:strong_rand_bytes(Bytes)).

password_hash(Password0) ->
    Password = bin(Password0),
    Salt = crypto:strong_rand_bytes(16),
    Iterations = 210000,
    Hash = crypto:pbkdf2_hmac(sha256, Password, Salt, Iterations, 32),
    iolist_to_binary([
        "pbkdf2-sha256$", integer_to_binary(Iterations), "$",
        base64:encode(Salt), "$", base64:encode(Hash)
    ]).

verify_password(Password0, Stored0) ->
    try
        Password = bin(Password0),
        Stored = str(Stored0),
        ["pbkdf2-sha256", IterS, SaltS, HashS] = string:split(Stored, "$", all),
        Iter = list_to_integer(IterS),
        Salt = base64:decode(SaltS),
        Expected = base64:decode(HashS),
        Actual = crypto:pbkdf2_hmac(sha256, Password, Salt, Iter, byte_size(Expected)),
        safe_equal(Expected, Actual)
    catch
        _:_ -> false
    end.

sanitize_username(Username0) ->
    U0 = lower(Username0),
    Filtered = [C || C <- U0,
        (C >= $a andalso C =< $z) orelse
        (C >= $0 andalso C =< $9) orelse
        C =:= $_ orelse C =:= $-],
    case Filtered of
        [] -> {error, <<"Username must contain letters or numbers.">>};
        _ when length(Filtered) < 3 -> {error, <<"Username must be at least 3 characters.">>};
        _ when length(Filtered) > 24 -> {error, <<"Username must be at most 24 characters.">>};
        _ -> {ok, unicode:characters_to_binary(Filtered)}
    end.

html_preview(Body0) ->
    Text = string:trim(str(Body0)),
    Short = case length(Text) > 160 of
        true -> string:slice(Text, 0, 157) ++ "...";
        false -> Text
    end,
    unicode:characters_to_binary(Short).


safe_equal(A, B) when is_binary(A), is_binary(B), byte_size(A) =:= byte_size(B) ->
    safe_equal_loop(binary_to_list(A), binary_to_list(B), 0) =:= 0;
safe_equal(_, _) -> false.

safe_equal_loop([], [], Acc) -> Acc;
safe_equal_loop([A | As], [B | Bs], Acc) -> safe_equal_loop(As, Bs, Acc bor (A bxor B)).
