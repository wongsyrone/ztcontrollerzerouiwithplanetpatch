# mkworld (vendored)

Upstream ZeroTierOne removed `attic/world/` — including `mkworld.cpp`, the only
tool that could generate a custom planet — in commit `21986038b` ("cleanup",
2025-07-31). The 1.16.2 tree has **no** replacement: grepping `mkworld` or
`genplanet` across `dev` returns nothing but a `.gitignore` entry.

To keep this fork's planet-patch feature working, `mkworld.cpp` is vendored
here and adapted to the modern source tree.

## Provenance

| | |
|---|---|
| Vendored from | [`zerotier/ZeroTierOne@b12dd19`](https://github.com/zerotier/ZeroTierOne/blob/b12dd19d441649ea159ba8b473e366c7694fdf76/attic/world/mkworld.cpp) — `attic/world/mkworld.cpp`, 2024-11-13 |
| Adapted for | [`zerotier/ZeroTierOne@899352e3`](https://github.com/zerotier/ZeroTierOne/tree/899352e38405968516bb12a770f0ac02f6058fa8) — `dev`, ZeroTierOne 1.16.2 |

## What had to change

Upstream folded `node/C25519.{cpp,hpp}` into `node/ECC.{cpp,hpp}` and widened the
key type from one Curve25519 key to a *key set* (C25519 for ECDH + Ed25519 for
signing). `ECC::Pair` keeps the same layout and the same `.pub.data` /
`.priv.data` accessors, so the adaptation is purely mechanical:

```c
#include <node/C25519.hpp>      ->  #include <node/ECC.hpp>
C25519::Pair                    ->  ECC::Pair
C25519::generate()              ->  ECC::generate()
ZT_C25519_PUBLIC_KEY_LEN   (32) ->  ZT_ECC_PUBLIC_KEY_SET_LEN   (64)
ZT_C25519_PRIVATE_KEY_LEN  (32) ->  ZT_ECC_PRIVATE_KEY_SET_LEN  (64)
```

Nothing else in the file needed touching: `World::make()`, `World::Root`,
`World::TYPE_PLANET` and `ZT_WORLD_ID_EARTH` are all unchanged.

## Verification

Compiled and executed against the real 1.16.2 headers on `debian:trixie`:

| Check | Result |
|---|---|
| Stock 4-root world (upstream's own roots) | **570 bytes** — exactly matches `ZT_DEFAULT_WORLD_LENGTH 570` in upstream `node/Topology.cpp` |
| `patch/planets.json` (1 root, Beijing) | **257 bytes** — same length as the committed `config/world.c` |
| Trailing checksum bytes | `0x27,0x09` in both |
| Root block (byte offset 178+) | byte-for-byte identical to committed `config/world.c` |
| Planet identity `a4de2130c2` | lands at offset 178 as expected |

## Build

`patch/patch.py` compiles this file; you rarely invoke it by hand. The
equivalent manual command is:

```sh
g++ -I./ZeroTierOne -I./ZeroTierOne/ext -o mkworld \
    ZeroTierOne/node/ECC.cpp \
    ZeroTierOne/node/Salsa20.cpp \
    ZeroTierOne/node/SHA512.cpp \
    ZeroTierOne/node/Identity.cpp \
    ZeroTierOne/node/Utils.cpp \
    ZeroTierOne/node/InetAddress.cpp \
    ZeroTierOne/osdep/OSUtils.cpp \
    ./mkworld/mkworld.cpp -std=c++11 -w
```

## Still disabled by default

The Dockerfile keeps `ENV PATCH_ALLOW=0`, so `patch/patch.py` exits
immediately and **no custom planet is built**. The image ships upstream's
default planet (`config/planet` ← `/app/config/planet`). Set `PATCH_ALLOW=1`
to enable it.

## ⚠️ Known inconsistency: `planet.secret` vs `config/world.c`

The committed `config/world.c` was signed by a key that is **not** the one in
`patch/planet.secret`:

| Field | `config/world.c` (bytes 17–80) | `patch/planet.secret` |
|---|---|---|
| `updatesMustBeSignedBy` | `6ac817d9…` | `ab5257bb…` |

The two also disagree on `ts` (2021-09-02 vs the 2019 stamp baked into
`mkworld.cpp`, which `patch.py` overwrites with `time.time()` anyway).

This is harmless while `PATCH_ALLOW=0`, because `world.c` is never consumed.
If you enable `PATCH_ALLOW=1`, regenerate `config/world.c` with the matching
key so the planet you serve is the planet you can actually sign updates for.