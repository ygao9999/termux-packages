# ============================================================
# postgresql build.sh  (官方 18.2 + 静态链接 patch)
#
# 基础：完全使用 termux 官方 master 的 build.sh
# 唯一改动：在 termux_step_post_configure 里 export LIBS
#           做部分静态链接（8 个核心库静态进二进制）
#
# 为什么放 post_configure 而不是 pre_configure？
#   configure 阶段会用 LIBS 跑测试程序，如果 LIBS 含
#   -Wl,-Bstatic -lssl ... 这种，链接器会尝试解析静态库，
#   空的 main 程序 + 静态库未解析符号 = configure exit 77
#   ("C compiler cannot create executables")。
#   post_configure 在所有 configure 探测完成后执行，
#   此时 LIBS 只影响 make 阶段的最终 link，不影响探测。
# ============================================================

TERMUX_PKG_HOMEPAGE=https://www.postgresql.org
TERMUX_PKG_DESCRIPTION="Object-relational SQL database"
TERMUX_PKG_LICENSE="PostgreSQL"
TERMUX_PKG_LICENSE_FILE="COPYRIGHT"
TERMUX_PKG_MAINTAINER="@termux"
TERMUX_PKG_VERSION="18.2"
TERMUX_PKG_SRCURL=https://ftp.postgresql.org/pub/source/v$TERMUX_PKG_VERSION/postgresql-$TERMUX_PKG_VERSION.tar.bz2
TERMUX_PKG_SHA256=5245bd1b79700d55b8e0575be0325ef61e7bbef627e6a616e4cf36ad4687be36
TERMUX_PKG_DEPENDS="libandroid-execinfo, libandroid-shmem, libicu, libuuid, libxml2, openssl, readline, zlib"

# 构建期需要 8 个静态库子包（提供 .a 做静态链接）
# 7 个官方有，apt 自动下载：
#   openssl-static, readline-static, libicu-static, zlib-static,
#   ossp-uuid-static, ncurses-static, libiconv-static
# libxml2-static 官方没有，由 workflow 从
# packages/postgresql/prebuilt/libxml2-static_*.deb 复制到 output/
# termux build-package.sh -i 会自动从 output/ 找到并 dpkg -i 进 build 环境
#
# --with-uuid=ossp 对齐 ossp-uuid-static
# 注意：ossp-uuid-static 只装 .a，header 在 ossp-uuid 包里（路径是
#       ossp-uuid/uuid.h）。但 postgresql configure 找的是 ossp/uuid.h
#       或 uuid.h，所以还需要在 pre_configure 里建 symlink。
TERMUX_PKG_BUILD_DEPENDS="openssl-static, readline-static, libicu-static, zlib-static, ossp-uuid-static, ossp-uuid, libxml2-static, ncurses-static, libiconv-static"
# - pgac_cv_prog_cc_LDFLAGS_EX_BE__Wl___export_dynamic: Needed to fix PostgreSQL 16 that
#   causes initdb failure: cannot locate symbol
# - pgac_cv_prog_cc_LDFLAGS__Wl___as_needed: Inform that the linker supports as-needed. It's
#   not stricly necessary but avoids unnecessary linking of binaries.
# - USE_UNNAMED_POSIX_SEMAPHORES: Avoid using System V semaphores which are disabled on Android.
# - ZIC=...: The zic tool is used to build the time zone database bundled with postgresql.
#   We specify a binary built in termux_step_host_build which has been patched to use symlinks
#   over hard links (which are not supported as of Android 6.0+).
#   There exists a --with-system-tzdata configure flag, but that does not work here as Android
#   uses a custom combined tzdata file.
TERMUX_PKG_EXTRA_CONFIGURE_ARGS="
--with-icu
--with-libxml
--with-openssl
--with-uuid=ossp
USE_UNNAMED_POSIX_SEMAPHORES=1
ZIC=${TERMUX_PKG_HOSTBUILD_DIR}/src/timezone/zic
pgac_cv_prog_cc_LDFLAGS_EX_BE__Wl___export_dynamic=yes
pgac_cv_prog_cc_LDFLAGS__Wl___as_needed=yes
"
TERMUX_PKG_RM_AFTER_INSTALL="
bin/ecpg
lib/libecpg*
share/man/man1/ecpg.1
"
TERMUX_PKG_HOSTBUILD=true
TERMUX_PKG_BREAKS="postgresql-contrib (<= 10.3-1), postgresql-dev"
TERMUX_PKG_REPLACES="postgresql-contrib (<= 10.3-1), postgresql-dev"
TERMUX_PKG_SERVICE_SCRIPT=("postgres" "mkdir -p ~/.postgres\nif [ -f \"~/.postgres/postgresql.conf\" ]; then DATADIR=\"~/.postgres\"; else DATADIR=\"$TERMUX_PREFIX/var/lib/postgresql\"; fi\nexec postgres -D \$DATADIR 2>&1")

termux_step_host_build() {
        # Build a native zic binary which we have patched to
        # use symlinks instead of hard links.
        $TERMUX_PKG_SRCDIR/configure --without-readline
        make -j "${TERMUX_PKG_MAKE_PROCESSES}"
}

termux_step_pre_configure() {
        # Certain packages are not safe to build on device because their
        # build.sh script deletes specific files in $TERMUX_PREFIX.
        if $TERMUX_ON_DEVICE_BUILD; then
                termux_error_exit "Package '$TERMUX_PKG_NAME' is not safe for on-device builds."
        fi

        # ossp-uuid 包把 header 装在 $PREFIX/include/ossp-uuid/uuid.h
        # 但 postgresql configure 找的是 ossp/uuid.h 或 uuid.h
        # 建 2 个 symlink 让 configure 能找到
        mkdir -p "${TERMUX_PREFIX}/include/ossp"
        ln -sf "${TERMUX_PREFIX}/include/ossp-uuid/uuid.h" \
               "${TERMUX_PREFIX}/include/ossp/uuid.h"
        ln -sf "${TERMUX_PREFIX}/include/ossp-uuid/uuid.h" \
               "${TERMUX_PREFIX}/include/uuid.h"
}

# ============================================================
# 唯一改动：termux_step_post_configure
# 在所有 configure 探测完成后，export LIBS 做部分静态链接。
# 此时 LIBS 只影响 make 阶段的最终 link，不影响 configure 探测。
# ============================================================
termux_step_post_configure() {
        # 8 个核心库静态链接进二进制，系统库走动态
        #
        # 依赖方向（左依赖右，被依赖者放右边）：
        #   ssl       → crypto
        #   readline  → history → tinfo
        #   icui18n   → icuuc → icudata
        #   z
        #   ossp-uuid (ossp, 独立) — 注意 .a 文件叫 libossp-uuid.a,所以 -lossp-uuid
        #   xml2      → iconv
        #
        # ${VAR:-} 是为了避免 termux set -u 报 unbound variable
        export LIBS="-Wl,-Bstatic \
                -lssl -lcrypto \
                -lreadline -lhistory -ltinfo \
                -licui18n -licuuc -licudata \
                -lz \
                -lossp-uuid \
                -lxml2 -liconv \
                -Wl,-Bdynamic \
                -ldl -lpthread -lm \
                ${LIBS:-}"
}

termux_step_post_make_install() {
        # Man pages are not installed by default:
        make -C doc/src/sgml install-man

        for contrib in \
                btree_gin \
                btree_gist \
                citext \
                dblink \
                fuzzystrmatch \
                hstore \
                pageinspect \
                pg_freespacemap \
                pg_stat_statements \
                pg_trgm \
                pgcrypto \
                pgrowlocks \
                postgres_fdw \
                tablefunc \
                unaccent \
                uuid-ossp \
                ; do
                (make -C contrib/${contrib} -s -j ${TERMUX_PKG_MAKE_PROCESSES} install)
        done
}
