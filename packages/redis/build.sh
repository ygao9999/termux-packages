TERMUX_PKG_HOMEPAGE=https://redis.io/
TERMUX_PKG_DESCRIPTION="In-memory data structure store used as a database, cache and message broker"
TERMUX_PKG_LICENSE="AGPL-V3"
TERMUX_PKG_MAINTAINER="@termux"
TERMUX_PKG_VERSION="1:8.8.0"
TERMUX_PKG_SRCURL=https://download.redis.io/releases/redis-${TERMUX_PKG_VERSION:2}.tar.gz
TERMUX_PKG_SHA256=88422181efb0c9c0abba332e3e391d409e1e13714b838931669235e5796f704b
TERMUX_PKG_AUTO_UPDATE=true
TERMUX_PKG_DEPENDS="libandroid-execinfo, libandroid-glob"   # 保留依赖，确保头文件及 .a 被安装
TERMUX_PKG_BUILD_IN_SRC=true
TERMUX_PKG_CONFFILES="etc/redis.conf"
TERMUX_PKG_BREAKS="valkey"
TERMUX_PKG_CONFLICTS="valkey"
TERMUX_PKG_REPLACES="valkey"

termux_step_pre_configure() {
    export PREFIX=$TERMUX_PREFIX
    export USE_JEMALLOC=no

    CPPFLAGS+=" -DHAVE_BACKTRACE"
    CFLAGS+=" $CPPFLAGS"

    # 强制使用静态库：直接指定 .a 的完整路径，避免搜索
    LDFLAGS=" -L$TERMUX_PREFIX/lib -Wl,-Bstatic $TERMUX_PREFIX/lib/libandroid-execinfo.a $TERMUX_PREFIX/lib/libandroid-glob.a -Wl,-Bdynamic"
}

termux_step_post_make_install() {
    install -Dm600 $TERMUX_PKG_SRCDIR/redis.conf $TERMUX_PREFIX/etc/redis.conf
}
