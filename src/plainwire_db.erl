-module(plainwire_db).
-behaviour(gen_server).

-export([start_link/0]).
-export([
    register_user/3, login_user/2, create_session/1, session_user/1,
    list_forums/0, list_threads/2, create_thread/4, get_thread/2, create_reply/3,
    list_conversations/1, get_messages/2, send_message/3,
    notifications/1, mark_notifications_read/1, user_by_username/1,
    counts/1
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {conn}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

register_user(Username, DisplayName, Password) -> call({register_user, Username, DisplayName, Password}).
login_user(Username, Password) -> call({login_user, Username, Password}).
create_session(UserId) -> call({create_session, UserId}).
session_user(Token) -> call({session_user, Token}).
list_forums() -> call(list_forums).
list_threads(ForumId, Query) -> call({list_threads, ForumId, Query}).
create_thread(UserId, ForumId, Title, Body) -> call({create_thread, UserId, ForumId, Title, Body}).
get_thread(UserId, ThreadId) -> call({get_thread, UserId, ThreadId}).
create_reply(UserId, ThreadId, Body) -> call({create_reply, UserId, ThreadId, Body}).
list_conversations(UserId) -> call({list_conversations, UserId}).
get_messages(UserId, OtherUsername) -> call({get_messages, UserId, OtherUsername}).
send_message(UserId, ToUsername, Body) -> call({send_message, UserId, ToUsername, Body}).
notifications(UserId) -> call({notifications, UserId}).
mark_notifications_read(UserId) -> call({mark_notifications_read, UserId}).
user_by_username(Username) -> call({user_by_username, Username}).
counts(UserId) -> call({counts, UserId}).

call(Msg) -> gen_server:call(?MODULE, Msg, 15000).

init([]) ->
    ok = filelib:ensure_dir(plainwire_config:db_path()),
    {ok, Conn} = esqlite3:open(plainwire_config:db_path()),
    ok = migrate(Conn),
    {ok, #state{conn = Conn}}.

handle_call(Msg, _From, #state{conn = Conn} = State) ->
    Reply = try route(Msg, Conn) catch Class:Reason:Stack ->
        error_logger:error_msg("plainwire_db error ~p:~p ~p~nmsg=~p~n", [Class, Reason, Stack, Msg]),
        {error, <<"Database error.">>}
    end,
    {reply, Reply, State}.

handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, #state{conn = Conn}) -> catch esqlite3:close(Conn), ok.
code_change(_Old, State, _Extra) -> {ok, State}.

route({register_user, Username0, DisplayName0, Password0}, Conn) ->
    case plainwire_util:sanitize_username(Username0) of
        {error, Reason} -> {error, Reason};
        {ok, Username} ->
            Password = plainwire_util:bin(Password0),
            DisplayName = clean_display(DisplayName0, Username),
            case byte_size(Password) < 8 of
                true -> {error, <<"Password must be at least 8 characters.">>};
                false ->
                    case one(Conn, "select id from users where username = ?", [Username]) of
                        {ok, _} -> {error, <<"Username is already registered.">>};
                        none ->
                            Now = plainwire_util:now(),
                            Hash = plainwire_util:password_hash(Password),
                            ok = exec(Conn, "insert into users(username, display_name, password_hash, created_at, last_seen) values (?, ?, ?, ?, ?)",
                                      [Username, DisplayName, Hash, Now, Now]),
                            {ok, [Id]} = one(Conn, "select last_insert_rowid()", []),
                            {ok, user_map(Id, Username, DisplayName, Now, Now)}
                    end
            end
    end;
route({login_user, Username0, Password0}, Conn) ->
    Username = unicode:characters_to_binary(string:lowercase(string:trim(plainwire_util:str(Username0)))),
    case one(Conn, "select id, username, display_name, password_hash, created_at, last_seen from users where username = ?", [Username]) of
        none -> {error, <<"Invalid username or password.">>};
        {ok, [Id, U, D, Hash, Created, _LastSeen]} ->
            case plainwire_util:verify_password(Password0, Hash) of
                true ->
                    Now = plainwire_util:now(),
                    ok = exec(Conn, "update users set last_seen = ? where id = ?", [Now, Id]),
                    {ok, user_map(Id, U, D, Created, Now)};
                false -> {error, <<"Invalid username or password.">>}
            end
    end;
route({create_session, UserId}, Conn) ->
    Token = plainwire_util:random_token(32),
    Now = plainwire_util:now(),
    Expires = Now + 60 * 60 * 24 * 30,
    ok = exec(Conn, "insert into sessions(token, user_id, created_at, expires_at) values (?, ?, ?, ?)", [Token, UserId, Now, Expires]),
    {ok, Token, Expires};
route({session_user, undefined}, _Conn) -> none;
route({session_user, <<>>}, _Conn) -> none;
route({session_user, Token}, Conn) ->
    Now = plainwire_util:now(),
    case one(Conn, "select u.id, u.username, u.display_name, u.created_at, u.last_seen from sessions s join users u on u.id = s.user_id where s.token = ? and s.expires_at > ?", [Token, Now]) of
        none -> none;
        {ok, [Id, U, D, Created, _LastSeen]} ->
            ok = exec(Conn, "update users set last_seen = ? where id = ?", [Now, Id]),
            {ok, user_map(Id, U, D, Created, Now)}
    end;
route(list_forums, Conn) ->
    Rows = rows(Conn, "select f.id, f.slug, f.name, f.description, f.position, count(distinct t.id), count(r.id), max(coalesce(r.created_at, t.created_at, 0)) from forums f left join threads t on t.forum_id = f.id left join replies r on r.thread_id = t.id group by f.id order by f.position, f.name", []),
    {ok, [forum_map(Row) || Row <- Rows]};
route({list_threads, ForumId0, Query0}, Conn) ->
    Query = string:trim(plainwire_util:str(Query0)),
    case parse_int(ForumId0) of
        all ->
            {Sql, Params} = thread_list_sql(undefined, Query),
            {ok, [thread_row_map(R) || R <- rows(Conn, Sql, Params)]};
        {ok, ForumId} ->
            {Sql, Params} = thread_list_sql(ForumId, Query),
            {ok, [thread_row_map(R) || R <- rows(Conn, Sql, Params)]};
        error -> {error, <<"Invalid forum id.">>}
    end;
route({create_thread, UserId, ForumId0, Title0, Body0}, Conn) ->
    case parse_int(ForumId0) of
        {ok, ForumId} ->
            Title = clean_title(Title0),
            Body = clean_body(Body0),
            case validate_thread(Conn, ForumId, Title, Body) of
                ok ->
                    Now = plainwire_util:now(),
                    ok = exec(Conn, "begin immediate", []),
                    try
                        ok = exec(Conn, "insert into threads(forum_id, user_id, title, created_at, updated_at, reply_count, locked) values (?, ?, ?, ?, ?, 0, 0)", [ForumId, UserId, Title, Now, Now]),
                        {ok, [ThreadId]} = one(Conn, "select last_insert_rowid()", []),
                        ok = exec(Conn, "insert into replies(thread_id, user_id, body, created_at, updated_at) values (?, ?, ?, ?, ?)", [ThreadId, UserId, Body, Now, Now]),
                        ok = exec(Conn, "commit", []),
                        {ok, ThreadId}
                    catch C:R:S ->
                        catch exec(Conn, "rollback", []),
                        erlang:raise(C, R, S)
                    end;
                Error -> Error
            end;
        error -> {error, <<"Invalid forum id.">>};
        all -> {error, <<"Forum id is required.">>}
    end;
route({get_thread, _UserId, ThreadId0}, Conn) ->
    case parse_int(ThreadId0) of
        {ok, ThreadId} ->
            case one(Conn, "select t.id, t.forum_id, f.name, t.user_id, u.username, u.display_name, t.title, t.created_at, t.updated_at, t.reply_count, t.locked from threads t join forums f on f.id = t.forum_id join users u on u.id = t.user_id where t.id = ?", [ThreadId]) of
                none -> {error, <<"Thread not found.">>};
                {ok, T} ->
                    ok = exec(Conn, "update threads set views = views + 1 where id = ?", [ThreadId]),
                    Replies = rows(Conn, "select r.id, r.thread_id, r.user_id, u.username, u.display_name, r.body, r.created_at, r.updated_at from replies r join users u on u.id = r.user_id where r.thread_id = ? order by r.created_at, r.id", [ThreadId]),
                    {ok, #{thread => thread_full_map(T), replies => [reply_map(R) || R <- Replies]}}
            end;
        _ -> {error, <<"Invalid thread id.">>}
    end;
route({create_reply, UserId, ThreadId0, Body0}, Conn) ->
    Body = clean_body(Body0),
    case parse_int(ThreadId0) of
        {ok, ThreadId} ->
            case byte_size(Body) < 2 of
                true -> {error, <<"Reply is too short.">>};
                false ->
                    case one(Conn, "select title, locked from threads where id = ?", [ThreadId]) of
                        none -> {error, <<"Thread not found.">>};
                        {ok, [_Title, Locked]} when Locked =:= 1 -> {error, <<"Thread is locked.">>};
                        {ok, [_Title, _Locked]} ->
                            Now = plainwire_util:now(),
                            ok = exec(Conn, "begin immediate", []),
                            try
                                ok = exec(Conn, "insert into replies(thread_id, user_id, body, created_at, updated_at) values (?, ?, ?, ?, ?)", [ThreadId, UserId, Body, Now, Now]),
                                {ok, [ReplyId]} = one(Conn, "select last_insert_rowid()", []),
                                ok = exec(Conn, "update threads set updated_at = ?, reply_count = reply_count + 1 where id = ?", [Now, ThreadId]),
                                notify_thread_participants(Conn, ThreadId, UserId, Body, Now),
                                ok = exec(Conn, "commit", []),
                                {ok, ReplyId}
                            catch C:R:S ->
                                catch exec(Conn, "rollback", []),
                                erlang:raise(C, R, S)
                            end
                    end
            end;
        _ -> {error, <<"Invalid thread id.">>}
    end;
route({list_conversations, UserId}, Conn) ->
    Rows = rows(Conn, "select u.id, u.username, u.display_name, max(m.created_at) as last_at, (select body from messages m2 where ((m2.sender_id = ? and m2.recipient_id = u.id) or (m2.sender_id = u.id and m2.recipient_id = ?)) order by m2.created_at desc, m2.id desc limit 1) as last_body, sum(case when m.recipient_id = ? and m.seen = 0 then 1 else 0 end) as unread from users u join messages m on ((m.sender_id = ? and m.recipient_id = u.id) or (m.sender_id = u.id and m.recipient_id = ?)) group by u.id order by last_at desc", [UserId, UserId, UserId, UserId, UserId]),
    {ok, [conversation_map(R) || R <- Rows]};
route({get_messages, UserId, OtherUsername0}, Conn) ->
    OtherUsername = unicode:characters_to_binary(string:lowercase(string:trim(plainwire_util:str(OtherUsername0)))),
    case one(Conn, "select id, username, display_name, created_at, last_seen from users where username = ?", [OtherUsername]) of
        none -> {error, <<"User not found.">>};
        {ok, [OtherId, U, D, Created, LastSeen]} ->
            ok = exec(Conn, "update messages set seen = 1 where sender_id = ? and recipient_id = ?", [OtherId, UserId]),
            Rows = rows(Conn, "select m.id, m.sender_id, su.username, su.display_name, m.recipient_id, ru.username, ru.display_name, m.body, m.created_at, m.seen from messages m join users su on su.id = m.sender_id join users ru on ru.id = m.recipient_id where (m.sender_id = ? and m.recipient_id = ?) or (m.sender_id = ? and m.recipient_id = ?) order by m.created_at, m.id", [UserId, OtherId, OtherId, UserId]),
            {ok, #{other => user_map(OtherId, U, D, Created, LastSeen), messages => [message_map(R) || R <- Rows]}}
    end;
route({send_message, UserId, ToUsername0, Body0}, Conn) ->
    ToUsername = unicode:characters_to_binary(string:lowercase(string:trim(plainwire_util:str(ToUsername0)))),
    Body = clean_body(Body0),
    case byte_size(Body) < 1 of
        true -> {error, <<"Message cannot be empty.">>};
        false ->
            case one(Conn, "select id, username, display_name from users where username = ?", [ToUsername]) of
                none -> {error, <<"Recipient not found.">>};
                {ok, [ToId, _U0, _D0]} when ToId =:= UserId -> {error, <<"You cannot send a message to yourself.">>};
                {ok, [ToId, U, D]} ->
                    Now = plainwire_util:now(),
                    SenderU = sender_username(Conn, UserId),
                    ok = exec(Conn, "insert into messages(sender_id, recipient_id, body, created_at, seen) values (?, ?, ?, ?, 0)", [UserId, ToId, Body, Now]),
                    {ok, [MessageId]} = one(Conn, "select last_insert_rowid()", []),
                    ok = create_notification(Conn, ToId, <<"message">>, <<"New private message from ", SenderU/binary>>, <<"#/messages/", SenderU/binary>>, Now),
                    {ok, #{id => MessageId, recipient => #{id => ToId, username => U, display_name => D}}}
            end
    end;
route({notifications, UserId}, Conn) ->
    Rows = rows(Conn, "select id, kind, body, url, seen, created_at from notifications where user_id = ? order by created_at desc, id desc limit 50", [UserId]),
    {ok, [notification_map(R) || R <- Rows]};
route({mark_notifications_read, UserId}, Conn) ->
    ok = exec(Conn, "update notifications set seen = 1 where user_id = ?", [UserId]),
    ok;
route({user_by_username, Username0}, Conn) ->
    U0 = unicode:characters_to_binary(string:lowercase(string:trim(plainwire_util:str(Username0)))),
    case one(Conn, "select id, username, display_name, created_at, last_seen from users where username = ?", [U0]) of
        none -> none;
        {ok, [Id, U, D, Created, LastSeen]} -> {ok, user_map(Id, U, D, Created, LastSeen)}
    end;
route({counts, UserId}, Conn) ->
    {ok, [UnreadMessages]} = one(Conn, "select count(*) from messages where recipient_id = ? and seen = 0", [UserId]),
    {ok, [UnreadNotifications]} = one(Conn, "select count(*) from notifications where user_id = ? and seen = 0", [UserId]),
    {ok, #{unread_messages => UnreadMessages, unread_notifications => UnreadNotifications}}.

migrate(Conn) ->
    _ = exec(Conn, "pragma journal_mode = wal", []),
    _ = exec(Conn, "pragma foreign_keys = on", []),
    Schema = [
        "create table if not exists users(id integer primary key autoincrement, username text not null unique, display_name text not null, password_hash text not null, created_at integer not null, last_seen integer not null)",
        "create table if not exists sessions(token text primary key, user_id integer not null references users(id) on delete cascade, created_at integer not null, expires_at integer not null)",
        "create table if not exists forums(id integer primary key autoincrement, slug text not null unique, name text not null, description text not null, position integer not null)",
        "create table if not exists threads(id integer primary key autoincrement, forum_id integer not null references forums(id) on delete cascade, user_id integer not null references users(id) on delete cascade, title text not null, created_at integer not null, updated_at integer not null, reply_count integer not null default 0, views integer not null default 0, locked integer not null default 0)",
        "create table if not exists replies(id integer primary key autoincrement, thread_id integer not null references threads(id) on delete cascade, user_id integer not null references users(id) on delete cascade, body text not null, created_at integer not null, updated_at integer not null)",
        "create table if not exists messages(id integer primary key autoincrement, sender_id integer not null references users(id) on delete cascade, recipient_id integer not null references users(id) on delete cascade, body text not null, created_at integer not null, seen integer not null default 0)",
        "create table if not exists notifications(id integer primary key autoincrement, user_id integer not null references users(id) on delete cascade, kind text not null, body text not null, url text not null, seen integer not null default 0, created_at integer not null)",
        "create index if not exists idx_threads_forum_updated on threads(forum_id, updated_at desc)",
        "create index if not exists idx_replies_thread on replies(thread_id, created_at)",
        "create index if not exists idx_messages_pair on messages(sender_id, recipient_id, created_at)",
        "create index if not exists idx_notifications_user on notifications(user_id, seen, created_at desc)"
    ],
    lists:foreach(fun(Sql) -> ok = exec(Conn, Sql, []) end, Schema),
    seed_forums(Conn),
    ok.

seed_forums(Conn) ->
    Forums = [
        {<<"general">>, <<"General Discussion">>, <<"Linux, Unix, workstations, servers, and day-to-day computing.">>, 10},
        {<<"install">>, <<"Installation & Boot">>, <<"Installers, bootloaders, partitions, initramfs, and recovery.">>, 20},
        {<<"hardware">>, <<"Hardware & Drivers">>, <<"Kernel modules, graphics, sound, networking, storage, and peripherals.">>, 30},
        {<<"servers">>, <<"Servers & Networking">>, <<"SSH, firewalls, web servers, mail, DNS, and home lab routing.">>, 40},
        {<<"desktop">>, <<"Desktop Environments">>, <<"Window managers, X11, Wayland, theming, fonts, and usability.">>, 50},
        {<<"programming">>, <<"Programming & Scripting">>, <<"Shell, C, Erlang, Gleam, Rust, Python, build systems, and tooling.">>, 60}
    ],
    lists:foreach(fun({Slug, Name, Desc, Pos}) ->
        ok = exec(Conn, "insert or ignore into forums(slug, name, description, position) values (?, ?, ?, ?)", [Slug, Name, Desc, Pos])
    end, Forums),
    ok.

clean_display(DisplayName0, Username) ->
    D = string:trim(plainwire_util:str(DisplayName0)),
    D1 = case D of "" -> plainwire_util:str(Username); _ -> D end,
    unicode:characters_to_binary(string:slice(D1, 0, 40)).

clean_title(Title0) ->
    unicode:characters_to_binary(string:slice(string:trim(plainwire_util:str(Title0)), 0, 120)).

clean_body(Body0) ->
    B0 = string:trim(plainwire_util:str(Body0)),
    unicode:characters_to_binary(string:slice(B0, 0, 12000)).

validate_thread(Conn, ForumId, Title, Body) ->
    case byte_size(Title) < 4 of
        true -> {error, <<"Title is too short.">>};
        false -> case byte_size(Body) < 2 of
            true -> {error, <<"Post body is too short.">>};
            false -> case one(Conn, "select id from forums where id = ?", [ForumId]) of
                none -> {error, <<"Forum not found.">>};
                {ok, _} -> ok
            end
        end
    end.

notify_thread_participants(Conn, ThreadId, SenderId, Body, Now) ->
    Users = rows(Conn, "select distinct user_id from replies where thread_id = ? and user_id != ?", [ThreadId, SenderId]),
    Preview = plainwire_util:html_preview(Body),
    Url = unicode:characters_to_binary(["#/thread/", integer_to_list(ThreadId)]),
    lists:foreach(fun([Uid]) ->
        create_notification(Conn, Uid, <<"reply">>, <<"New reply: ", Preview/binary>>, Url, Now)
    end, Users),
    ok.

create_notification(Conn, UserId, Kind, Body, Url, Now) ->
    exec(Conn, "insert into notifications(user_id, kind, body, url, seen, created_at) values (?, ?, ?, ?, 0, ?)", [UserId, Kind, Body, Url, Now]).

sender_username(Conn, UserId) ->
    case one(Conn, "select username from users where id = ?", [UserId]) of
        {ok, [U]} -> U;
        none -> <<"unknown">>
    end.

thread_list_sql(undefined, "") ->
    {"select t.id, t.forum_id, f.name, t.user_id, u.username, u.display_name, t.title, t.created_at, t.updated_at, t.reply_count, t.views from threads t join forums f on f.id = t.forum_id join users u on u.id = t.user_id order by t.updated_at desc, t.id desc limit 200", []};
thread_list_sql(undefined, Query) ->
    Like = unicode:characters_to_binary(["%", Query, "%"]),
    {"select t.id, t.forum_id, f.name, t.user_id, u.username, u.display_name, t.title, t.created_at, t.updated_at, t.reply_count, t.views from threads t join forums f on f.id = t.forum_id join users u on u.id = t.user_id where t.title like ? order by t.updated_at desc, t.id desc limit 200", [Like]};
thread_list_sql(ForumId, "") ->
    {"select t.id, t.forum_id, f.name, t.user_id, u.username, u.display_name, t.title, t.created_at, t.updated_at, t.reply_count, t.views from threads t join forums f on f.id = t.forum_id join users u on u.id = t.user_id where t.forum_id = ? order by t.updated_at desc, t.id desc limit 200", [ForumId]};
thread_list_sql(ForumId, Query) ->
    Like = unicode:characters_to_binary(["%", Query, "%"]),
    {"select t.id, t.forum_id, f.name, t.user_id, u.username, u.display_name, t.title, t.created_at, t.updated_at, t.reply_count, t.views from threads t join forums f on f.id = t.forum_id join users u on u.id = t.user_id where t.forum_id = ? and t.title like ? order by t.updated_at desc, t.id desc limit 200", [ForumId, Like]}.

parse_int(undefined) -> all;
parse_int(<<>>) -> all;
parse_int(<<"all">>) -> all;
parse_int("all") -> all;
parse_int(V) when is_integer(V) -> {ok, V};
parse_int(V) ->
    try {ok, list_to_integer(plainwire_util:str(V))}
    catch _:_ -> error end.

user_map(Id, Username, DisplayName, Created, LastSeen) ->
    #{id => Id, username => Username, display_name => DisplayName, created_at => Created, last_seen => LastSeen}.

forum_map([Id, Slug, Name, Desc, Pos, ThreadCount, ReplyCount, LastAt]) ->
    #{id => Id, slug => Slug, name => Name, description => Desc, position => Pos, thread_count => ThreadCount, reply_count => ReplyCount, last_activity => LastAt}.

thread_row_map([Id, ForumId, ForumName, UserId, Username, DisplayName, Title, Created, Updated, ReplyCount, Views]) ->
    #{id => Id, forum_id => ForumId, forum_name => ForumName, user => #{id => UserId, username => Username, display_name => DisplayName}, title => Title, created_at => Created, updated_at => Updated, reply_count => ReplyCount, views => Views}.

thread_full_map([Id, ForumId, ForumName, UserId, Username, DisplayName, Title, Created, Updated, ReplyCount, Locked]) ->
    #{id => Id, forum_id => ForumId, forum_name => ForumName, user => #{id => UserId, username => Username, display_name => DisplayName}, title => Title, created_at => Created, updated_at => Updated, reply_count => ReplyCount, locked => Locked}.

reply_map([Id, ThreadId, UserId, Username, DisplayName, Body, Created, Updated]) ->
    #{id => Id, thread_id => ThreadId, user => #{id => UserId, username => Username, display_name => DisplayName}, body => Body, created_at => Created, updated_at => Updated}.

conversation_map([UserId, Username, DisplayName, LastAt, LastBody, Unread]) ->
    #{user => #{id => UserId, username => Username, display_name => DisplayName}, last_at => LastAt, last_body => LastBody, unread => case Unread of null -> 0; _ -> Unread end}.

message_map([Id, SenderId, SenderUsername, SenderDisplay, RecipientId, RecipientUsername, RecipientDisplay, Body, Created, Seen]) ->
    #{id => Id, sender => #{id => SenderId, username => SenderUsername, display_name => SenderDisplay}, recipient => #{id => RecipientId, username => RecipientUsername, display_name => RecipientDisplay}, body => Body, created_at => Created, seen => Seen}.

notification_map([Id, Kind, Body, Url, Seen, Created]) ->
    #{id => Id, kind => Kind, body => Body, url => Url, seen => Seen, created_at => Created}.

exec(Conn, Sql, Params) ->
    case query(Conn, Sql, Params) of
        {ok, _Rows} -> ok;
        Error -> Error
    end.

rows(Conn, Sql, Params) ->
    case query(Conn, Sql, Params) of
        {ok, Rows} -> Rows;
        {error, Error} -> erlang:error({sqlite, Error})
    end.

one(Conn, Sql, Params) ->
    case rows(Conn, Sql, Params) of
        [] -> none;
        [Row | _] -> {ok, Row}
    end.

query(Conn, Sql, Params) ->
    case esqlite3:prepare(Conn, Sql) of
        {ok, Stmt} ->
            try
                ok = esqlite3:bind(Stmt, Params),
                collect(Stmt, [])
            after
                catch esqlite3:release(Stmt)
            end;
        Error -> {error, Error}
    end.

collect(Stmt, Acc) ->
    case esqlite3:step(Stmt) of
        done ->
            {ok, lists:reverse(Acc)};
        '$done' ->
            {ok, lists:reverse(Acc)};
        {done, _} ->
            {ok, lists:reverse(Acc)};
        {row, Row0} ->
            Row = case is_tuple(Row0) of
                true -> tuple_to_list(Row0);
                false -> Row0
            end,
            collect(Stmt, [Row | Acc]);
        Row0 when is_tuple(Row0) ->
            collect(Stmt, [tuple_to_list(Row0) | Acc]);
        Row0 when is_list(Row0) ->
            collect(Stmt, [Row0 | Acc]);
        {error, Error} ->
            {error, Error};
        Error ->
            {error, Error}
    end.
