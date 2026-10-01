#!/usr/bin/env bash
#
# Build the MongoDB Database Tools as Percona packages.
#
# Option contract, properties-file hand-off between stages and overall structure mirror
# percona-server-mongodb/percona-packaging/scripts/psmdb_builder.sh, so a Jenkins job for
# this repo is a structural copy of the PSMDB one. Everything C++/bazel/telemetry-related
# is gone; what is left is the mongo-tools part, unchanged in behaviour.

abort() {
    printf "Error: %s\n" "${1:-unknown error}" >&2
    exit "${2:-1}"
}

shell_quote_string() {
  echo "$1" | sed -e 's,\([^a-zA-Z0-9/_.=-]\),\\\1,g'
}

usage () {
    cat <<EOF
Usage: $0 [OPTIONS]
    The following options may be given :
        --builddir=DIR      Absolute path to the dir where all actions will be performed
        --get_sources       Source will be downloaded from github
        --build_src_rpm     If it is set - src rpm will be built
        --build_src_deb     If it is set - source deb package will be built
        --build_rpm         If it is set - rpm will be built
        --build_deb         If it is set - deb will be built
        --build_tarball     If it is set - binary tarball will be built
        --install_deps      Install build dependencies(root privilages are required)
        --branch            mongo-tools tag/branch to build (default: MONGO_TOOLS_TAG_VERSION)
        --repo              mongo-tools repo to build from
        --version           Package version (default: derived from --branch)
        --release           Package release (default: 1)
        --debug             build unstripped binaries
        --help) usage ;;
Example $0 --builddir=/tmp/TOOLS --get_sources=1 --build_src_rpm=1 --build_rpm=1
EOF
        exit 1
}

append_arg_to_args () {
  args="$args "$(shell_quote_string "$1")
}

parse_arguments() {
    pick_args=
    if test "$1" = PICK-ARGS-FROM-ARGV
    then
        pick_args=1
        shift
    fi

    for arg do
        val=$(echo "$arg" | sed -e 's;^--[^=]*=;;')
        case "$arg" in
            --builddir=*) WORKDIR="$val" ;;
            --build_src_rpm=*) SRPM="$val" ;;
            --build_src_deb=*) SDEB="$val" ;;
            --build_rpm=*) RPM="$val" ;;
            --build_deb=*) DEB="$val" ;;
            --get_sources=*) SOURCE="$val" ;;
            --build_tarball=*) TARBALL="$val" ;;
            --branch=*) BRANCH="${val:-$BRANCH}" ;;
            --repo=*) REPO="$val" ;;
            --install_deps=*) INSTALL="$val" ;;
            --version=*) VERSION="$val" ;;
            --release=*) RELEASE="$val" ;;
            --debug=*) DEBUG="$val" ;;
            --help) usage ;;
            *)
              if test -n "$pick_args"
              then
                  append_arg_to_args "$arg"
              fi
              ;;
        esac
    done
}

path_affix() {
    local dir="$1"
    local at_the_end="$2"

    [ -n "$dir" ] || abort '`path_affix`: empty directory or too few arguments'
    [ "$dir" = "/" ] || dir="${dir%/}"

    case "$at_the_end" in
        "at_the_end") at_the_end="true" ;;
        "") at_the_end="false" ;;
        *) abort "\`path_affix\`: invalid second argument value \`$at_the_end\`" ;;
    esac

    local path="${PATH:-}"
    case ":${path}:" in
        *:"$dir":*)
            ;;
        *)
            if $at_the_end; then
                export PATH="${path:+$path:}$dir"
            else
                export PATH="$dir${path:+:$path}"
            fi
            ;;
    esac
}

set_gopath() {
    local dir="$1"
    [ -n "$dir" ] || abort '`set_gopath`: empty directory or too few arguments'
    export GOPATH="$dir"
    path_affix "$GOPATH/bin" "at_the_end"
}

check_workdir(){
    [ -n "$WORKDIR" ] || abort "WORKDIR is empty"
    [ "x$WORKDIR" = "x$CURDIR" ] && abort "Current directory cannot be used for building!"
    [ -d "$WORKDIR" ] || abort "\`$WORKDIR\` is not a directory."
}

get_system(){
    if [ -f /etc/redhat-release ]; then
        RHEL=$(rpm --eval %rhel)
        ARCH=$(echo $(uname -m) | sed -e 's:i686:i386:g')
        OS_NAME="el$RHEL"
        OS="rpm"
    elif [ -f /etc/amazon-linux-release ]; then
        RHEL=$(rpm --eval %amzn)
        ARCH=$(echo $(uname -m) | sed -e 's:i686:i386:g')
        OS_NAME="amzn$RHEL"
        OS="rpm"
    else
        ARCH=$(uname -m)
        OS_NAME="$(lsb_release -sc)"
        OS="deb"
    fi
    return
}

install_golang() {
    if [ "$ARCH" = "x86_64" ]; then
      GO_ARCH="amd64"
    elif [ "$ARCH" = "aarch64" ]; then
      GO_ARCH="arm64"
    else
        abort "Unsupported architecture: $ARCH"
    fi

    GO_TAR="go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
    GO_URL="https://downloads.percona.com/downloads/packaging/go/${GO_TAR}"
    DL_PATH="/tmp/${GO_TAR}"

    wget -q "$GO_URL" -O "$DL_PATH" || abort "failed to download \`$GO_URL\`"
    rm -rf /usr/local/go*
    tar --transform "s|^go|go${GO_VERSION}|" -C /usr/local -xzf "$DL_PATH" \
        || abort '`tar` failed to unpack the Go toolchain'
    ln -s "/usr/local/go${GO_VERSION}" /usr/local/go
    rm -f "$DL_PATH"
    /usr/local/go/bin/go version || abort 'the installed Go toolchain does not run'
}

install_deps() {
    if [ $INSTALL = 0 ]
    then
        echo "Dependencies will not be installed"
        return;
    fi
    [ "$(id -u)" -eq 0 ] || abort "It is not possible to instal dependencies. Please run as root"
    if [ "x$OS" = "xrpm" ]; then
      yum -y install wget git tar which findutils diffutils
      # gcc + krb5-devel: the `gssapi` build tag is cgo, linking -lgssapi_krb5 -lkrb5
      yum -y install gcc krb5-devel
      yum -y install rpm-build rpmlint
    else
      export DEBIAN_FRONTEND=noninteractive
      apt-get -y update
      apt-get -y install wget git tar lsb-release
      apt-get -y install gcc libkrb5-dev
      apt-get -y install debhelper devscripts dpkg-dev
    fi
    install_golang
    return;
}

get_sources(){
    if [ $SOURCE = 0 ]
    then
        echo "Sources will not be downloaded"
        return;
    fi
    cd "${WORKDIR}" || abort "cannot cd to \`$WORKDIR\`"
    rm -rf "${PRODUCT}"*
    rm -f "${PROPERTIES}"

    git clone --depth 1 --branch "$BRANCH" --recurse-submodules --shallow-submodules "$REPO" "${PRODUCT}" \
        || abort "failed to clone \`$REPO\` at \`$BRANCH\`"
    cd "${PRODUCT}" || abort "cannot cd to \`$WORKDIR/$PRODUCT\`"

    TOOLS_COMMIT="$(git rev-parse HEAD)" || abort '`git rev-parse HEAD` failed'
    # Package version is the upstream tools version, deliberately decoupled from PSMDB.
    # Strip a leading `v`/`r` if the tag ever carries one.
    [ -n "$VERSION" ] || VERSION="$(echo "$BRANCH" | sed -e 's/^[vr]//')"

    # Consumed by the spec's %build and by debian/rules, which source it. Same variable
    # names as PSMDB uses, so the ported seds need no edits.
    {
        echo "export PSMDB_TOOLS_COMMIT_HASH=\"${TOOLS_COMMIT}\""
        echo "export PSMDB_TOOLS_REVISION=\"${VERSION}\""
    } > set_tools_revision.sh
    chmod +x set_tools_revision.sh

    # Ported one-to-one from psmdb_builder.sh. Upstream's platform.DetectLocal() shells out
    # to `lsb_release`, which is absent on the RHEL-family images, and Oracle Linux reports
    # `OracleServer`, which is not in upstream's platform table. Detection therefore cannot
    # succeed, and on failure the build silently drops -tags (no gssapi) and -buildmode=pie.
    # Forcing rhel93 on every OS is what PSMDB does; the platform only selects build tags
    # (identical for all platforms) and, on Linux, -buildmode=pie.
    # https://jira.mongodb.org/browse/TOOLS-3318
    sed -i '/GetLinuxDistroAndVersion()/ s/os, version, err = GetLinuxDistroAndVersion()/os, version, err = "rhel", "9.3", nil/' release/platform/platform.go \
        || abort '`sed` on release/platform/platform.go failed'

    apply_go_deps

    # Packaging layout inside the source tree, mirroring psmdb_builder.sh:257-258 so the
    # spec (%{src_dir}/manpages/*) and debian/percona-server-mongodb-tools.manpages
    # (manpages/<tool>.1) both resolve.
    mkdir -p percona-packaging
    cp -a "${PKGROOT}/redhat"   percona-packaging/ || abort 'copying redhat/ failed'
    cp -a "${PKGROOT}/debian"   percona-packaging/ || abort 'copying debian/ failed'
    cp -a "${PKGROOT}/manpages" percona-packaging/ || abort 'copying manpages/ failed'
    cp -a "${PKGROOT}/docs"     percona-packaging/ || abort 'copying docs/ failed'
    cp -a percona-packaging/manpages .            || abort 'copying manpages to source root failed'
    cp -a percona-packaging/docs/*  .             || abort 'copying docs to source root failed'

    REVISION="$(echo "$TOOLS_COMMIT" | cut -c1-7)"
    {
        echo "PRODUCT=${PRODUCT}"
        echo "PRODUCT_FULL=${PRODUCT}-${VERSION}-${RELEASE}"
        echo "VERSION=${VERSION}"
        echo "RELEASE=${RELEASE}"
        echo "TOOLS_TAG=${BRANCH}"
        echo "TOOLS_REPO=${REPO}"
        echo "TOOLS_COMMIT=${TOOLS_COMMIT}"
        echo "REVISION=${REVISION}"
        # Consumed by the Jenkins job, which greps UPLOAD out of this file to derive the
        # artifact paths. Same shape as mongosh-packaging's builder.
        echo "UPLOAD=UPLOAD/experimental/BUILDS/${PRODUCT}/${PRODUCT}-${VERSION}-${RELEASE}/${BRANCH}/${REVISION}/${BUILD_ID:-}"
    } > "${WORKDIR}/${PROPERTIES}"

    find . -name '.git' -prune -exec rm -rf {} +

    cd "${WORKDIR}" || abort "cannot cd to \`$WORKDIR\`"
    mv "${PRODUCT}" "${PRODUCT}-${VERSION}-${RELEASE}"
    tar --owner=0 --group=0 -czf "${PRODUCT}-${VERSION}-${RELEASE}.tar.gz" "${PRODUCT}-${VERSION}-${RELEASE}" \
        || abort '`tar` failed to create the source tarball'
    mkdir -p "$WORKDIR/source_tarball" "$CURDIR/source_tarball"
    cp "${PRODUCT}-${VERSION}-${RELEASE}.tar.gz" "$WORKDIR/source_tarball"
    cp "${PRODUCT}-${VERSION}-${RELEASE}.tar.gz" "$CURDIR/source_tarball"
    rm -rf "${PRODUCT}-${VERSION}-${RELEASE}"
    return
}

# Bump Go dependencies above what upstream pins, to clear CVEs. Values live in
# go-deps.env; see the warning in that file about them going stale on a tag bump.
apply_go_deps() {
    [ -r "${PKGROOT}/go-deps.env" ] || abort "cannot read \`${PKGROOT}/go-deps.env\`"
    . "${PKGROOT}/go-deps.env"
    path_affix "/usr/local/go/bin"
    set_gopath "$PWD/../"

    if [ -n "${GO_DEPS_DROP_REPLACE:-}" ]; then
        local args=""
        local mod
        for mod in $GO_DEPS_DROP_REPLACE; do
            args="$args -dropreplace $mod"
        done
        go mod edit $args || abort '`go mod edit` failed'
    fi
    if [ -n "${GO_DEPS_GET:-}" ]; then
        go get $GO_DEPS_GET || abort '`go get` failed'
    fi
    go mod tidy   || abort '`go mod tidy` failed'
    go mod vendor || abort '`go mod vendor` failed'
    # Make downloaded Go packages writable so they can be removed later
    if [ -d "$GOPATH/pkg" ]; then
        chmod -R u+w "$GOPATH/pkg" || abort '`chmod` failed'
    fi
}

# Upstream's getBuildFlags only logs when version stamping or platform detection fails and
# builds anyway, so a green build can still ship unstamped or Kerberos-less binaries.
# Called after every path that produces binaries.
assert_binaries() {
    local bindir="$1"
    local want_version="$2"
    local want_commit="$3"
    [ -x "${bindir}/mongodump" ] || abort "\`assert_binaries\`: \`${bindir}/mongodump\` is missing"

    "${bindir}/mongodump" --version | grep -q "^mongodump version: ${want_version}$" \
        || { "${bindir}/mongodump" --version; abort "version stamping failed: expected \`${want_version}\`"; }
    "${bindir}/mongodump" --version | grep -q "^git version: ${want_commit}$" \
        || { "${bindir}/mongodump" --version; abort "commit stamping failed: expected \`${want_commit}\`"; }
    ldd "${bindir}/mongodump" | grep -q libgssapi_krb5 \
        || { ldd "${bindir}/mongodump"; abort 'built without the gssapi build tag'; }

    local tool
    for tool in $TOOLS; do
        [ -x "${bindir}/${tool}" ] || abort "\`assert_binaries\`: \`${bindir}/${tool}\` is missing"
    done
    echo "assert_binaries: ${want_version} / ${want_commit} / gssapi OK"
}

# Build the tools out of an unpacked source tree. $1 is that tree; binaries land in $1/bin.
# The seds are ported one-to-one from psmdb_builder.sh / spec.template / debian/rules:
# `sed '14d'` drops the goke/pkg/git import and shifts the file by one line, which is why
# `sed '246,254d'` lands on the original 247-255. Tied to the upstream tag -- re-verify on
# every bump of MONGO_TOOLS_TAG_VERSION.
compile_tools() {
    local srcdir="$1"
    local gobase="$2"

    path_affix "/usr/local/go/bin"
    export GOROOT="/usr/local/go/"
    set_gopath "${gobase}/"
    export GOBINPATH="/usr/local/go/bin"

    mkdir -p "$GOPATH/src/github.com/mongodb" || abort '`mkdir` for GOPATH failed'
    rm -rf "$GOPATH/src/github.com/mongodb/mongo-tools"
    cp -r "$srcdir" "$GOPATH/src/github.com/mongodb/mongo-tools" || abort '`cp` into GOPATH failed'

    cd "$GOPATH/src/github.com/mongodb/mongo-tools" || abort 'cannot cd into the GOPATH copy'
    . ./set_tools_revision.sh
    sed -i '14d' buildscript/build.go            || abort '`sed 14d` failed'
    sed -i '246,254d' buildscript/build.go       || abort '`sed 246,254d` failed'
    sed -i "s:versionStr,:\"$PSMDB_TOOLS_REVISION\",:" buildscript/build.go || abort '`sed` versionStr failed'
    sed -i "s:gitCommit):\"$PSMDB_TOOLS_COMMIT_HASH\"):" buildscript/build.go || abort '`sed` gitCommit failed'
    ./make build || abort '`./make build` failed'

    mkdir -p "${srcdir}/bin"
    mv bin/* "${srcdir}/bin" || abort 'moving built binaries failed'
    assert_binaries "${srcdir}/bin" "$PSMDB_TOOLS_REVISION" "$PSMDB_TOOLS_COMMIT_HASH"
}

get_source_tarball() {
    local filepath=$(find "$WORKDIR/source_tarball" -name "${PRODUCT}*.tar.gz" 2>/dev/null | sort | tail -n1)
    [ -n "$filepath" ] || filepath=$(find "$CURDIR/source_tarball" -name "${PRODUCT}*.tar.gz" 2>/dev/null | sort | tail -n1)
    [ -n "$filepath" ] || abort 'source tarball does not exist; add the `--get_sources` option to create it'
    cp "$filepath" "$WORKDIR/" || abort "\`get_source_tarball\`: failed to copy \`$filepath\`"
    echo "$(basename "$filepath")"
}

get_source_rpm_package() {
    local filepath=$(find "$WORKDIR/srpm" -name "${PRODUCT}*.src.rpm" 2>/dev/null | sort | tail -n1)
    [ -n "$filepath" ] || filepath=$(find "$CURDIR/srpm" -name "${PRODUCT}*.src.rpm" 2>/dev/null | sort | tail -n1)
    [ -n "$filepath" ] || abort 'source rpm package does not exist; add the `--build_src_rpm` option to create it'
    cp "$filepath" "$WORKDIR/" || abort "\`get_source_rpm_package\`: failed to copy \`$filepath\`"
    echo "$(basename "$filepath")"
}

get_deb_sources() {
    local ext=$1
    [ -n "$ext" ] || abort '`get_deb_sources`: empty or missing extension argument'
    local filepath=$(find "$WORKDIR/source_deb" -name "${PRODUCT}*.$ext" 2>/dev/null | sort | tail -n1)
    [ -n "$filepath" ] || filepath=$(find "$CURDIR/source_deb" -name "${PRODUCT}*.$ext" 2>/dev/null | sort | tail -n1)
    [ -n "$filepath" ] || abort 'source deb package does not exist; add the `--build_src_deb` option to create it'
    cp "$filepath" "$WORKDIR/" || abort "\`get_deb_sources\`: failed to copy \`$filepath\`"
}

build_srpm(){
    if [ $SRPM = 0 ]
    then
        echo "SRC RPM will not be created"
        return;
    fi
    [ "x$OS" = "xrpm" ] || abort "Can't build source rpm on a non-rpm-based OS"
    cd "$WORKDIR" || abort "cannot cd to \`$WORKDIR\`"
    TARFILE="$(get_source_tarball)"
    source "${WORKDIR}/${PROPERTIES}"
    rm -fr rpmbuild
    mkdir -vp rpmbuild/{SOURCES,SPECS,BUILD,SRPMS,RPMS}

    SRC_DIR=${TARFILE%.tar.gz}
    tar xzf "${WORKDIR}/${TARFILE}" --wildcards '*/percona-packaging' --strip=1 \
        || abort '`tar` failed to extract percona-packaging'
    SPEC_TMPL=$(find percona-packaging/redhat -name "${PRODUCT}.spec.template" | sort | tail -n1)
    [ -n "$SPEC_TMPL" ] || abort 'spec template not found in the source tarball'

    sed -e "s:@@SOURCE_TARBALL@@:$(basename ${TARFILE}):g" \
        -e "s:@@VERSION@@:${VERSION}:g" \
        -e "s:@@RELEASE@@:${RELEASE}:g" \
        -e "s:@@SRC_DIR@@:$SRC_DIR:g" \
        ${SPEC_TMPL} > rpmbuild/SPECS/$(basename ${SPEC_TMPL%.template})
    mv -fv "${TARFILE}" "${WORKDIR}/rpmbuild/SOURCES"

    rpmbuild -bs --define "_topdir ${WORKDIR}/rpmbuild" --define "dist .generic" \
        rpmbuild/SPECS/$(basename ${SPEC_TMPL%.template}) || abort '`rpmbuild -bs` failed'
    mkdir -p "${WORKDIR}/srpm" "${CURDIR}/srpm"
    cp rpmbuild/SRPMS/*.src.rpm "${CURDIR}/srpm"
    cp rpmbuild/SRPMS/*.src.rpm "${WORKDIR}/srpm"
    return
}

build_rpm(){
    if [ $RPM = 0 ]
    then
        echo "RPM will not be created"
        return;
    fi
    [ "x$OS" = "xrpm" ] || abort "Can't build rpm on a non-rpm-based OS"
    SRC_RPM="$(get_source_rpm_package)"
    cd "$WORKDIR" || abort "cannot cd to \`$WORKDIR\`"
    rm -fr rpmbuild
    mkdir -vp rpmbuild/{SOURCES,SPECS,BUILD,SRPMS,RPMS}
    cp "$SRC_RPM" rpmbuild/SRPMS/

    echo "RHEL=${RHEL}" >> "${PROPERTIES}"
    echo "ARCH=${ARCH}" >> "${PROPERTIES}"

    path_affix "/usr/local/go/bin"
    set_gopath "$(pwd)/"

    rpmbuild --define "_topdir ${WORKDIR}/rpmbuild" --define "dist .$OS_NAME" \
        --rebuild "rpmbuild/SRPMS/$SRC_RPM"
    return_code=$?
    if [ $return_code != 0 ]; then
        abort "\`rpmbuild\` failed with code $return_code" $return_code
    fi
    mkdir -p "${WORKDIR}/rpm" "${CURDIR}/rpm"
    cp rpmbuild/RPMS/*/*.rpm "${WORKDIR}/rpm"
    cp rpmbuild/RPMS/*/*.rpm "${CURDIR}/rpm"
}

build_source_deb(){
    if [ $SDEB = 0 ]
    then
        echo "Source deb package will not be created"
        return;
    fi
    [ "x$OS" = "xdeb" ] || abort "Can't build source deb on a non-deb-based OS"
    cd "$WORKDIR" || abort "cannot cd to \`$WORKDIR\`"
    rm -rf "${PRODUCT}"-*
    rm -f *.dsc *.orig.tar.gz *.debian.tar.* *.changes
    TARFILE="$(get_source_tarball)"
    source "${WORKDIR}/${PROPERTIES}"

    DEBIAN=$(lsb_release -sc)
    tar zxf "${TARFILE}" || abort '`tar` failed to unpack the source tarball'
    BUILDDIR=${TARFILE%.tar.gz}

    rm -fr "${BUILDDIR}/debian"
    cp -av "${BUILDDIR}/percona-packaging/debian" "${BUILDDIR}" || abort 'copying debian/ failed'

    mv "${TARFILE}" "${PRODUCT}_${VERSION}.orig.tar.gz"
    cd "${BUILDDIR}" || abort "cannot cd to \`$BUILDDIR\`"
    dch -D unstable --force-distribution -v "${VERSION}-${RELEASE}" \
        "Update to new MongoDB Database Tools version ${VERSION}" || abort '`dch` failed'
    dpkg-buildpackage -S || abort '`dpkg-buildpackage -S` failed'
    cd ../
    mkdir -p "$WORKDIR/source_deb" "$CURDIR/source_deb"
    for d in "$WORKDIR/source_deb" "$CURDIR/source_deb"; do
        cp *.debian.tar.* "$d"
        cp *_source.changes "$d"
        cp *.dsc "$d"
        cp *.orig.tar.gz "$d"
    done
}

build_deb(){
    if [ $DEB = 0 ]
    then
        echo "Deb package will not be created"
        return;
    fi
    [ "x$OS" = "xdeb" ] || abort "Can't build deb on a non-deb-based OS"
    for file in 'dsc' 'orig.tar.gz' 'changes' 'debian.tar*'
    do
        get_deb_sources $file
    done
    cd "$WORKDIR" || abort "cannot cd to \`$WORKDIR\`"
    rm -fv *.deb
    export DEBIAN=$(lsb_release -sc)
    export ARCH=$(echo $(uname -m) | sed -e 's:i686:i386:g')
    echo "DEBIAN=${DEBIAN}" >> "${PROPERTIES}"
    echo "ARCH=${ARCH}" >> "${PROPERTIES}"
    source "${WORKDIR}/${PROPERTIES}"

    DSC=$(basename $(find . -name '*.dsc' | sort | tail -n1))
    dpkg-source -x ${DSC} || abort '`dpkg-source -x` failed'
    cd "${PRODUCT}-${VERSION}" || abort "cannot cd to \`${PRODUCT}-${VERSION}\`"

    # PSMDB_TOOLS_REVISION / PSMDB_TOOLS_COMMIT_HASH are read by debian/rules from the
    # environment; same mechanism as psmdb_builder.sh:805.
    . ./set_tools_revision.sh

    dch -m -D "${DEBIAN}" --force-distribution -v "${VERSION}-${RELEASE}.${DEBIAN}" 'Update distribution' \
        || abort '`dch` failed'

    path_affix "/usr/local/go/bin"
    set_gopath "$PWD/../"

    dpkg-buildpackage -rfakeroot -us -uc -b || abort '`dpkg-buildpackage -b` failed'

    cd "$WORKDIR"
    mkdir -p "$CURDIR/deb" "$WORKDIR/deb"
    # debian/rules uses dh_strip --dbg-package, so the debug symbols come out as a normal
    # percona-server-mongodb-tools-dbg *.deb and there is no *.ddeb. The .ddeb copy stays
    # as a safety net: if anyone ever switches to automatic dbgsym, a 31 MB artifact must
    # not vanish silently the way it did before this was added.
    for d in "$WORKDIR/deb" "$CURDIR/deb"; do
        cp $WORKDIR/*.deb "$d"
        cp $WORKDIR/*.ddeb "$d" 2>/dev/null || true
    done
    ls -la "$WORKDIR/deb"
}

build_tarball(){
    if [ $TARBALL = 0 ]
    then
        echo "Binary tarball will not be created"
        return;
    fi
    cd "$WORKDIR" || abort "cannot cd to \`$WORKDIR\`"
    TARFILE="$(get_source_tarball)"
    source "${WORKDIR}/${PROPERTIES}"

    SRCDIR=${TARFILE%.tar.gz}
    rm -rf "${SRCDIR}"
    tar xzf "${TARFILE}" || abort '`tar` failed to unpack the source tarball'

    compile_tools "${WORKDIR}/${SRCDIR}" "${WORKDIR}/build_tools"

    cd "$WORKDIR" || abort "cannot cd to \`$WORKDIR\`"
    TARNAME="${PRODUCT}-${VERSION}-${RELEASE}-${ARCH}.${OS_NAME}"
    rm -rf "${TARNAME}"
    mkdir -p "${TARNAME}/bin"
    cp "${SRCDIR}"/bin/* "${TARNAME}/bin/" || abort 'copying binaries into the tarball tree failed'
    cp "${SRCDIR}/LICENSE.md" "${SRCDIR}/THIRD-PARTY-NOTICES" "${TARNAME}/" \
        || abort 'copying LICENSE/THIRD-PARTY-NOTICES failed'

    if [ ${DEBUG} = 0 ]; then
        strip --strip-debug "${TARNAME}"/bin/* || abort '`strip` failed'
    fi
    assert_binaries "${WORKDIR}/${TARNAME}/bin" "${VERSION}" "${TOOLS_COMMIT}"

    tar --owner=0 --group=0 -czf "${TARNAME}.tar.gz" "${TARNAME}" \
        || abort '`tar` failed to create the binary tarball'
    mkdir -p "${WORKDIR}/tarball" "${CURDIR}/tarball"
    cp "${TARNAME}.tar.gz" "${WORKDIR}/tarball"
    cp "${TARNAME}.tar.gz" "${CURDIR}/tarball"
}

CURDIR="$(pwd)"
# Repo root, so the script can be invoked from anywhere
PKGROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

args=
WORKDIR=
SRPM=0
SDEB=0
RPM=0
DEB=0
SOURCE=0
TARBALL=0
OS_NAME=
ARCH=
OS=
RHEL=
INSTALL=0
TOOLS_COMMIT=
DEBUG=0

PRODUCT=percona-server-mongodb-tools
PROPERTIES="${PRODUCT}.properties"
TOOLS="bsondump mongostat mongofiles mongoexport mongoimport mongorestore mongodump mongotop"
GO_VERSION="1.26.8"

REPO="https://github.com/mongodb/mongo-tools.git"
BRANCH="$(cat "${PKGROOT}/MONGO_TOOLS_TAG_VERSION" 2>/dev/null || echo master)"
VERSION=
RELEASE="1"

parse_arguments PICK-ARGS-FROM-ARGV "$@"

path_affix "/usr/bin"
export GOROOT="/usr/local/go"
path_affix "$GOROOT/bin"

check_workdir
get_system
install_deps
get_sources
build_tarball
build_srpm
build_source_deb
build_rpm
build_deb
