TERMUX_PKG_HOMEPAGE=https://www.postgresql.org
TERMUX_PKG_DESCRIPTION="Object-relational SQL database"
TERMUX_PKG_LICENSE="PostgreSQL"
TERMUX_PKG_LICENSE_FILE="COPYRIGHT"
TERMUX_PKG_MAINTAINER="@termux"
TERMUX_PKG_VERSION="18.2"
TERMUX_PKG_SRCURL=https://ftp.postgresql.org/pub/source/v$TERMUX_PKG_VERSION/postgresql-$TERMUX_PKG_VERSION.tar.bz2
TERMUX_PKG_SHA256=5245bd1b79700d55b8e0575be0325ef61e7bbef627e6a616e4cf36ad4687be36
TERMUX_PKG_DEPENDS="libandroid-execinfo, libandroid-shmem, libicu, libuuid, libxml2, openssl, readline, zlib"
TERMUX_PKG_EXTRA_CONFIGURE_ARGS="
--with-icu
--with-libxml
--with-openssl
--with-uuid=e2fs
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
    # 构建本机 zic 工具（使用符号链接代替硬链接）
    $TERMUX_PKG_SRCDIR/configure --without-readline
    make -j "${TERMUX_PKG_MAKE_PROCESSES}"
}

termux_step_pre_configure() {
    if $TERMUX_ON_DEVICE_BUILD; then
        termux_error_exit "Package '$TERMUX_PKG_NAME' is not safe for on-device builds."
    fi
}

# 定义静态链接所需的 LDFLAGS（在 configure 之后使用，避免干扰配置测试）
# 注意：此变量将在后续 make 阶段被显式传递
STATIC_LDFLAGS="-L$TERMUX_PREFIX/lib -Wl,-Bstatic -lssl -lcrypto -licuuc -licui18n -licudata -lxml2 -lreadline -luuid -lz -Wl,-Bdynamic"

termux_step_post_configure() {
    # 将静态链接标志保存为环境变量，供后续 make 使用
    export LDFLAGS="$STATIC_LDFLAGS"
}

# 重写 make 步骤，显式传递 LDFLAGS
termux_step_make() {
    make -j ${TERMUX_PKG_MAKE_PROCESSES} LDFLAGS="$LDFLAGS"
}

# 重写 make install 步骤，同样传递 LDFLAGS（虽然安装通常不链接，但为了保险）
termux_step_make_install() {
    make -j ${TERMUX_PKG_MAKE_PROCESSES} install LDFLAGS="$LDFLAGS"
}

termux_step_post_make_install() {
    # 安装手册页
    make -C doc/src/sgml install-man

    # 编译并安装 contrib 扩展（需确保每个扩展的链接也使用静态库）
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
        (make -C contrib/${contrib} -s -j ${TERMUX_PKG_MAKE_PROCESSES} install LDFLAGS="$LDFLAGS")
    done
}
