# Plainwire Forum (Old Concept)

Plainwire is a small real-time technical forum and private-message server with an Erlang backend and a plain HTML/CSS/JavaScript frontend.

Self hostable, or on our servers **(DEVELOPMENT WILL RESUME IN THE FUTURE)**

# Use Plainwire Relay (Recommended)

URL: https://plainwire.kokonico.me

[Source Repo](https://github.com/RobertFlexx/Plainwire)

## Features

- Real account registration and login
- PBKDF2-SHA256 password hashing
- Cookie sessions stored in SQLite
- Forum categories, threads, replies, view counts
- Private messages between registered users
- Notifications for direct messages and thread replies
- Live updates through WebSockets
- Polling fallback so updates still arrive if the WebSocket drops
- Auto-refresh that preserves text currently being typed
- SQLite database with WAL mode
- No fake threads, fake members, or bot posting

## Requirements

- Erlang/OTP 25 or newer recommended
- rebar3
- SQLite support through the `esqlite` Erlang dependency

## Run locally

```sh
rebar3 get-deps
rebar3 shell --apps plainwire_forum
```

Open:

```text
http://localhost:8080
```

## LAN use

Start the server and have another computer on the same network open:

```text
http://YOUR-LAN-IP:8080
```

Find your Linux LAN IP with:

```sh
ip addr
```

## Configuration

```sh
PORT=8080 PLAINWIRE_DB=data/plainwire.sqlite3 rebar3 shell --apps plainwire_forum
```

If you deploy behind HTTPS, set secure cookies:

```sh
COOKIE_SECURE=true PORT=8080 rebar3 shell --apps plainwire_forum
```

## Database

The default database path is:

```text
data/plainwire.sqlite3
```

The schema is created automatically on boot. Forum categories are inserted if missing, but user content is never fabricated.

## Production notes
**This web app can be used as a base/library, or it itself on or not on our servers.**

This is a solid small-forum base, but treat deployment like any other web app:

- Put it behind HTTPS.
- Back up `data/plainwire.sqlite3`.
- Use a reverse proxy such as nginx or Caddy if exposing it to the internet.
- Do not run it as root.
- For a public internet forum, add moderation tools, rate limits, email verification, and stronger abuse handling before opening it widely.

## Project layout

```text
src/                 Erlang backend
priv/static/         HTML/CSS/JS frontend
data/                SQLite database directory
rebar.config         Build/dependency config
```


## Notice

this is an old **concept** of what it was gonna be.
we will bring it back :)
