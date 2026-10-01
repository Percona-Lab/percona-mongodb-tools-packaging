# percona-mongodb-tools-packaging

Packaging and build scripts for **`percona-server-mongodb-tools`** — the MongoDB Database
Tools (`bsondump`, `mongodump`, `mongoexport`, `mongofiles`, `mongoimport`,
`mongorestore`, `mongostat`, `mongotop`) as shipped by Percona.

## Why this repo exists

The tools used to be compiled as part of the Percona Server for MongoDB build. A CVE in one
of their Go dependencies therefore required rebuilding all of PSMDB — about 10 hours of C++
build time for a change that compiles in seconds. This repo decouples them: a security
rebuild is now an edit to `go-deps.env`, a release bump, and one pipeline run.

## Versioning

The package carries the **upstream tools version** with an independent release counter —
e.g. `percona-server-mongodb-tools-100.18.0-1`. It is deliberately **not** tied to the
PSMDB version any more. No `Epoch` is needed: `100.x` sorts above every PSMDB version in
both rpm and dpkg.

## Building

Requires a container of the target OS (the binaries link the system krb5 libraries, so each
artifact is built where it will run).

```sh
scripts/mongo_tools_builder.sh --builddir=/tmp/build --install_deps=1
scripts/mongo_tools_builder.sh --builddir=/tmp/build --get_sources=1 --branch=100.18.0 --release=1
scripts/mongo_tools_builder.sh --builddir=/tmp/build --build_rpm=1
```

`--repo` and `--branch` default to upstream and `MONGO_TOOLS_TAG_VERSION`; point them at a
fork to build patched source.
