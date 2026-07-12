# ============================================================
# postgresql build.sh  (官方 18.2 + 静态链接 patch)
#
# 静态链接 8 个核心库的真正方法：
#   - LIBS 环境变量在 post_configure 里 export 没用，因为
#     autotools 把 LIBS = @LIBS@ 烤进 Makefile（优先级 3），
#     环境变量（优先级 4）被覆盖。
#   - TERMUX_PKG_EXTRA_MAKE_ARGS='LIBS=...' 全局覆盖 LIBS 会影响
#     zic 等工具的链接（zic 不需要 ssl/readline/icu 等），导致
#     undefined symbol: pg_printf 等错误。
#   - 正确做法：patch src/backend/Makefile，只在 postgres 后端
#     二进制 link 时加 -l:libNAME.a 强制静态链接。
#   - 用 $(filter-out ...) 删掉 configure 烤进 @LIBS@ 的动态版本
#     (-lssl -lcrypto -lreadline -lz -luuid -lossp-uuid -lxml2)，
#     否则会同时 link .so 和 .a（冲突 + 浪费）。
#
# 参考证据：
#   - termux-packages/packages/postgresql/src-backend-Makefile.patch
#     官方原本就有 LIBS += -landroid-shmem -llog
#   - termux 仓库里大量包用 -l:libNAME.a 做强制静态链接
#     (binutils, sox, fluidsynth, cryptopp, clamav 等)
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
# 注意：ossp-uuid-static 只装 .a（libossp-uuid.a），header 在 ossp-uuid 包
#       里（路径是 ossp-uuid/uuid.h）。但 postgresql configure 找的是
#       ossp/uuid.h 或 uuid.h，所以还需要在 pre_configure 里建 symlink。
TERMUX_PKG_BUILD_DEPENDS="openssl-static, readline-static, libicu-static, zlib-static, ossp-uuid-static, ossp-uuid, libxml2-static, ncurses-static, libiconv-static"

# ----- configure args -----
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
        $TERMUX_PKG_SRCDIR/configure --without-readline
        make -j "${TERMUX_PKG_MAKE_PROCESSES}"
}

termux_step_pre_configure() {
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

        # 关键：把预编译的 libxml2.a cp 到 termux prefix
        # termux -i 不会从 output/ 拉 BUILD_DEPENDS 里的 libxml2-static,
        # 所以必须手动 cp。在 pre_configure 里做，确保 termux 完成 cache
        # extract 之后才 cp，不会被覆盖。
        if [ -f "${TERMUX_PACKAGE_DIR}/prebuilt/libxml2-static_2.15.3-2_aarch64.deb" ]; then
                echo "=== Pre-install libxml2.a from prebuilt deb ==="
                cd /tmp && rm -rf pg-libxml2-extract && mkdir pg-libxml2-extract && cd pg-libxml2-extract
                ar x "${TERMUX_PACKAGE_DIR}/prebuilt/libxml2-static_2.15.3-2_aarch64.deb"
                tar -xJf data.tar.xz
                cp -v data/data/com.termux/files/usr/lib/libxml2.a "${TERMUX_PREFIX}/lib/"
                ls -lh "${TERMUX_PREFIX}/lib/libxml2.a"
        fi
}

termux_step_post_make_install() {
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

