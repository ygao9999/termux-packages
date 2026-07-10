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

# 定义静态链接所需的库（使用 -l: 强制指定静态库文件名，避免依赖 -Bstatic）
# 同时保留 -L 指定路径，确保链接器能找到这些 .a 文件
STATIC_LIBRARIES="-L$TERMUX_PREFIX/lib -l:libssl.a -l:libcrypto.a -l:libicuuc.a -l:libicui18n.a -l:libicudata.a -l:libxml2.a -l:libreadline.a -l:libuuid.a -l:libz.a"

termux_step_post_configure() {
    # 查找并收集静态库的绝对路径
    local STATIC_LIBS=""
    for libname in ssl crypto icuuc icui18n icudata xml2 readline uuid z; do
        local libfile=$(find $TERMUX_PREFIX -name "lib${libname}.a" -print -quit 2>/dev/null)
        if [ -z "$libfile" ]; then
            echo "Error: Static library lib${libname}.a not found under $TERMUX_PREFIX"
            exit 1
        fi
        STATIC_LIBS="$STATIC_LIBS $libfile"
    done

    export LDFLAGS="$LDFLAGS $STATIC_LIBS"
    export LIBS="$STATIC_LIBS"

    # 复用主机 zic
    if [ -f "${TERMUX_PKG_HOSTBUILD_DIR}/src/timezone/zic" ]; then
        mkdir -p "${TERMUX_PKG_BUILDDIR}/src/timezone"
        cp -f "${TERMUX_PKG_HOSTBUILD_DIR}/src/timezone/zic" "${TERMUX_PKG_BUILDDIR}/src/timezone/zic"
        touch "${TERMUX_PKG_BUILDDIR}/src/timezone/zic"
    else
        echo "Warning: Host zic not found"
    fi
}

termux_step_make() {
    # 显式传递 LDFLAGS 和 LIBS，确保静态库被正确链接
    make -j ${TERMUX_PKG_MAKE_PROCESSES} LDFLAGS="$LDFLAGS" LIBS="$LIBS"
}

termux_step_make_install() {
    make -j ${TERMUX_PKG_MAKE_PROCESSES} install LDFLAGS="$LDFLAGS" LIBS="$LIBS"
}

termux_step_post_make_install() {
    # 安装手册页
    make -C doc/src/sgml install-man

    # 编译并安装 contrib 扩展，同样传递 LDFLAGS 和 LIBS
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
        (make -C contrib/${contrib} -s -j ${TERMUX_PKG_MAKE_PROCESSES} install LDFLAGS="$LDFLAGS" LIBS="$LIBS")
    done
}
