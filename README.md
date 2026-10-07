# docker-zerotier-controller

Dockernized ZeroTierOne controller with the zero-ui web interface. [中文讨论](https://v2ex.com/t/799623)

Built on ZeroTierOne `dev` (currently `899352e3`, version 1.16.2).

---

## Two flavours

This image is built in one of two modes, selected at build time. They are
genuinely different products, not configurations of one.

|                | `embedded` (default)            | `central`                                |
| -------------- | ------------------------------- | ---------------------------------------- |
| Image tag      | `:latest`                       | `:latest-central`                        |
| Controller     | bundled **FileDB**              | **CentralDB** + Postgres                 |
| Storage        | JSON files in `controller.d`    | Postgres tables `*_ctl`                  |
| External DB    | **none**                        | **required**                             |
| Migrations     | not applicable                  | `golang-migrate`, applied on boot       |
| Image size     | ~186 MB                         | ~238 MB                                 |
| Best for       | a single self-hosted node       | shared controller across several nodes  |

This is a build-time distinction inside ZeroTierOne, not a runtime switch.
`ZT1_CENTRAL_CONTROLLER` is a superset of `ZT_NONFREE` that swaps FileDB for
CentralDB and adds the Postgres/Redis/PubSub/BigTable backends; when it is on,
`EmbeddedNetworkController::init()` rejects any `controllerDbPath` that does not
start with `postgres:` and the daemon aborts.

The flavour is baked in as `ZT_CONTROLLER_FLAVOR` and the container's s6 services
read it at startup. A mismatch fails fast with an explanatory message rather than
producing a daemon that dies moments later:

- `ZT_PGSQL=true` on an `embedded` image -> refused
- `ZT_CONTROLLER_FLAVOR=central` without `ZT_PGSQL=true` -> refused

### Choosing a flavour

Use `embedded` unless you specifically need a Postgres-backed controller. It is
the default for a reason: it needs no external service, so it comes up from a
single `docker run`, and that is what "self-deploy, self-maintain" requires.

Use `central` when the controller state must be shared between nodes or you
already run Postgres.

---

## Quick start: embedded

```bash
docker run -d --name zt \
  -p 3000:3000 -p 4000:4000 -p 9993:9993 -p 9993:9993/udp \
  -v zt-config:/app/config \
  wongsyrone/ztcontrollerzerouiwithplanetpatch:latest
```

Then sign in to <http://localhost:4000> with `admin` / `zero-ui`.

Keep the `/app/config` volume. Without it the controller signs a new identity on
every boot and existing members lose their controller.

### Peer

Download `planet` from the web interface, then place it in the peer's
configuration directory and start `zerotier-one`:

```bash
cp planet /var/lib/zerotier-one/planet
zerotier-one /var/lib/zerotier-one
```

On the logged-in home screen there is a **File name to download** box. Type
`planet` and press the button. This is a feature of the bundled zero-ui fork
(upstream zero-ui has no such control); it serves `/app/frontend/down_folder/`
through the `/downfile` route, and this image symlinks `/app/config/planet` into
that directory so the controller's own planet is what you get.

The route requires a logged-in session and returns `401` otherwise:

```bash
# 401 {"error":"401 Not authorized, must Login to download"}
curl http://localhost:4000/downfile/planet

# 200, the planet binary
TOKEN=$(curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"zero-ui"}' \
  http://localhost:4000/auth/login | jq -r .token)
curl -H "Authorization: token $TOKEN" -o planet http://localhost:4000/downfile/planet
```

Note the header form is `Authorization: token <token>`, not `Bearer`. Note also
that `/app/static/planet`, which older versions of this README used, returns 404
— that path is not served.

---

## Quick start: central

`central` needs a reachable Postgres. A working stack is in
[`test/docker-compose.central.yml`](test/docker-compose.central.yml):

```bash
docker compose -f test/docker-compose.central.yml up -d
docker compose -f test/docker-compose.central.yml logs -f zerotier
docker compose -f test/docker-compose.central.yml down -v
```

Both containers reach `healthy` unattended; the controller applies the schema
migrations itself on first boot. To verify:

```bash
# controller API
docker compose -f test/docker-compose.central.yml exec zerotier \
  sh -c 'curl -s -H "Authorization: bearer $(cat /app/config/authtoken.secret)" \
         http://localhost:9993/controller/network'

# migrations that were applied
docker compose -f test/docker-compose.central.yml exec pg \
  psql -U zt -d zt -c 'SELECT version FROM controller_migrations ORDER BY version;'
```

Without compose, point the image at an existing Postgres:

```bash
docker run -d --name zt \
  -e ZT_PGSQL=true \
  -e ZT_PGSQL_HOST=db.example.com -e ZT_PGSQL_PORT=5432 \
  -e ZT_PGSQL_DB=zt -e ZT_PGSQL_USER=zt -e ZT_PGSQL_PASS=changeme \
  -e ZT_PGSQL_INIT=true \
  -p 3000:3000 -p 4000:4000 -p 9993:9993 -p 9993:9993/udp \
  -v zt-config:/app/config \
  wongsyrone/ztcontrollerzerouiwithplanetpatch:latest-central
```

#### `ZT_PGSQL_INIT` is a one-shot flag

It names the operation "create the schema", which only ever needs to happen once.
Set it and the container creates the database, runs `migrate up` against
`/migrations`, then clears the flag. Re-running the container is a no-op:
migrate reports `no change`.

Migrations are applied by [golang-migrate](https://github.com/golang-migrate/migrate),
the same tool and invocation upstream's own
`ext/central-controller-docker/main.sh` uses, and they are read straight out of the
ZeroTierOne source tree the builder already downloaded
(`ext/central-controller-docker/migrations`).

Nothing is vendored in this repository. The applied set lives in
`controller_migrations`, which migrate itself creates and maintains, so a
migration added upstream after the pinned ZeroTierOne commit is picked up by the
next image build with no local edit. This image therefore has no SQL files and no
migration logic of its own to keep in step with upstream.

---

## Ports

| Port     | Purpose                                                       |
| -------- | ------------------------------------------------------------- |
| `9993`  | ZeroTier, TCP and UDP                                          |
| `4000`  | zero-ui. Serves **HTTPS** when `/app/backend/tls/fullchain.pem` and `privkey.pem` are both present (TLSv1.3+), otherwise falls back to plain HTTP and logs `cannot read cert ...`. No certificates ship in the image, so out of the box this is HTTP. Drop in a cert/key pair and the fork picks it up without a restart |
| `3000`  | declared for compatibility; zero-ui does not bind it unless a proxy is in front |

The controller's own management API is on `9993` and requires the bearer token
from `/app/config/authtoken.secret`. It is not the same endpoint as the UI, and
it is not exposed through zero-ui.

---

## Environment variables

### Both flavours

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `ZT_PRIMARY_PORT` | `9993` | ZeroTierOne `primaryPort` |
| `ZU_LISTEN_PORT` | `4000` | zero-ui backend port |
| `LISTEN_ADDRESS` | `0.0.0.0` | zero-ui bind address |
| `ZU_CONTROLLER_ENDPOINT` | `http://localhost:9993/` | controller API base URL |
| `ZU_DEFAULT_USERNAME` | `admin` | first-run admin |
| `ZU_DEFAULT_PASSWORD` | `zero-ui` | first-run password |
| `ZT_DATAPATH` | `data/db.json` | zero-ui's own data file; zero-ui never touches Postgres |

See the [zero-ui README](https://github.com/dec0dOS/zero-ui) for the rest.

### Bundled zero-ui fork

`ZERO_UI_COMMIT` pins [`wongsyrone/zero-ui`](https://github.com/wongsyrone/zero-ui)
branch `myself-change-on-main`, not upstream `dec0dOS/zero-ui`. Relative to
upstream it adds:

| Change | Effect |
| ------ | ------ |
| `backend/routes/downfile.js`, mounted at `/downfile` | authenticated file download from `frontend/down_folder`; gated on a logged-in session, or on `ZU_DISABLE_AUTH=true` |
| `HomeLoggedIn/components/DownloadFile` | the "File name to download" UI that drives that route |
| `frontend/down_folder/` | download target; this image symlinks `/app/config/planet` in here |
| TLS + cert/key auto-reload in `backend/bin/www.js` | see the port table above |
| `backend/utils/controller-api.js` | Windows (`C:\ProgramData\ZeroTier\One`) and macOS (`/Library/Application Support/ZeroTier/One`) `authtoken.secret` locations |
| TLS certificate reload on file change | drop new `fullchain.pem` / `privkey.pem` into `/app/backend/tls` and the server picks them up without a restart |

### `central` only

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `ZT_PGSQL` | `false` | must be `true` on this flavour |
| `ZT_PGSQL_HOST` / `_PORT` / `_DB` / `_USER` / `_PASS` | | connection details |
| `ZT_PGSQL_INIT` | `false` | one-shot schema creation, see above |
| `ZT_LISTEN_MODE` | `pgsql` | `pgsql`, `redis` or `pubsub` |
| `ZT_STATUS_MODE` | `pgsql` | `pgsql`, `redis` or `bigtable` |
| `ZT_ASSIGNED_CENTRAL_VERSION` | `all` | `cv1`, `cv2` or `all` |
| `ZT_EXPORTER_ENDPOINT` | unset | OpenTelemetry collector. The `otel` block is written **only** when this is set; omitting the key entirely is the supported way to say "no tracing" and avoids a startup warning |
| `ZT_REDIS` | `false` | Redis for pub/sub instead of Postgres LISTEN/NOTIFY |

---

## Build

```bash
# embedded (default)
docker build --force-rm -t zt-controller:local .

# central
docker build --force-rm --build-arg ZT_CONTROLLER_FLAVOR=central \
  -t zt-controller-central:local .
```

The central build compiles OpenTelemetry's SDK and google-cloud-cpp from source
via `scripts/bootstrap-deps.sh`, which dominates build time. The embedded build
skips both.

---

## Custom planet

**Currently disabled.** `PATCH_ALLOW=0`, so the image ships ZeroTierOne's default
planet. This was already the case before the 1.16 upgrade.

To build a custom planet, edit `patch/planets.json` and build with
`--build-arg PATCH_ALLOW=1`:

```json
{
  "planets": [
    {
      "Location": "Beijing",
      "Identity": "a4de2130c2:0:ab5257bb05cd2fb8044fe26483f6d27b57124ca7b350fb3e0f07d405c68c4416094dbc836bf62ed483072501aa3384dff3c74ac50050c1bfbb1dc657001ef6a1",
      "Endpoints": ["127.0.0.1/9993"]
    }
  ]
}
```

`patch/planet.public` and `patch/planet.secret` hold the key pair. See
[`mkworld/README.md`](mkworld/README.md) for why the generator is vendored in
this repo, how it was adapted to ZeroTierOne 1.16, and a known inconsistency
between `planet.secret` and the committed `config/world.c` worth resolving
before enabling this.

---

## Local patches

`zt_patches/` holds three quilt patches against ZeroTierOne, applied by the
builder. They exist because upstream behaviour is unwanted here, not because
anything is broken:

| Patch | Why |
| ----- | --- |
| `0001-disable-sso` | OIDC single sign-on is not wanted; also keeps the Rust `rustybits` crate from being linked |
| `0002-gc-sections` | smaller binary via `-ffunction-sections` + `--gc-sections` |
| `0003-enable-http-log` | HTTP request/response logging |

To move to a newer ZeroTierOne `dev` commit, update `ZEROTIER_ONE_COMMIT` in the
`Dockerfile` and check that all three still apply:

```bash
docker run --rm -v "$PWD:/repo" -w /repo debian:trixie bash -c "
  apt-get update -qq && apt-get install -y -qq quilt git >/dev/null 2>&1
  curl -sL https://codeload.github.com/zerotier/ZeroTierOne/tar.gz/\$ZEROTIER_ONE_COMMIT \
    | tar xz && cp -r zt_patches ZeroTierOne-*/
  cd ZeroTierOne-* && QUILT_PATCHES=zt_patches quilt push -a"
```

---

## Layout in the image

```
/app/
├── config/      ZeroTierOne config: identity.*, authtoken.secret, local.conf, controller.d/
├── backend/     zero-ui backend
├── frontend/    zero-ui static files
└── ZeroTierOne/ zerotier-one (plus zerotier-cli / zerotier-idtool symlinks)
```

`/migrations/` holds the controller migrations, copied out of the ZeroTierOne
source tree. `/usr/local/bin/migrate` is present only on the `central` flavour.
The `zerotier` s6 service applies the migrations on `central` only.

---

## FAQ

**How is this different from the official [zero-ui](https://github.com/dec0dOS/zero-ui) or [ztncui](https://github.com/key-networks/ztncui) images?**

Those are controller *interfaces*. This provides the full operational set:
planet, controller, and UI, as a single ZeroTierOne process plus zero-ui.

**Can I upgrade an existing `ztc_*` database?**

No. The schema was renamed wholesale in ZeroTierOne 1.16: `ztc_network`,
`ztc_member` and `ztc_controller` became `networks_ctl`,
`network_memberships_ctl` and `controllers_ctl`, and several tables were folded
into a `configuration` jsonb column. `central` assumes a fresh database. The
`embedded` flavour never had a database to migrate.

**Why does port 4000 serve HTTP out of the box?**

The bundled zero-ui fork starts an HTTPS server only when both
`/app/backend/tls/fullchain.pem` and `privkey.pem` exist; otherwise it logs
`cannot read cert ...` and serves plain HTTP. The image ships an empty
`/app/backend/tls`, so HTTP is the default. Supply your own pair to get HTTPS,
and note the fork reloads them on file change rather than needing a restart.

---

## Change Log

- 20261007 - ZeroTierOne `dev` 899352e3 (1.16.2); CMake controller build;
  `embedded` / `central` flavours; document both.
- 20220215 - Update software versions and Readme
- 20211206 - Add FAQ section.
- 20210904 - Update peer's instructions.
- 20210902 - First Release.