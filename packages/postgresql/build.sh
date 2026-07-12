# ============================================================
# postgresql build.sh  (官方 18.2 + 静态链接 patch)
#
# 静态链接 8 个核心库的真正方法：
#   - LIBS 环境变量在 post_configure 里 export 没用，因为
#     autotools 把 LIBS = @LIBS@ 烤进 Makefile（优先级 3），
#     环境变量（优先级 4）被覆盖。
#   - 正确做法：用 TERMUX_PKG_EXTRA_MAKE_ARGS 传 LIBS=... 命令行
#     参数（优先级 2，beat makefile 赋值）。
#   - 用 -l:libNAME.a 语法强制链接 .a 文件，不走 .so 优先搜索。
#
# 参考证据：
#   - termux-packages build-package.sh:778 调用 termux_step_post_configure
#   - termux_step_make.sh:15 用 make -j N（无 -e 无 LIBS=）
#   - GNU make 优先级：命令行 > Makefile 赋值 > 环境变量
#   - termux-packages/packages/postgresql/src-backend-Makefile.patch
#     用 LIBS += -landroid-shmem -llog 加额外库
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

# ============================================================
# 关键改动：用 TERMUX_PKG_EXTRA_MAKE_ARGS 传 LIBS= 命令行参数
#
# GNU make 优先级：命令行参数 (LIBS=...) beat Makefile 赋值 (LIBS = @LIBS@)
# 所以 make 会用我们指定的 LIBS，不用 configure 烤的 @LIBS@
#
# 用 -l:libNAME.a 语法强制链接 .a 文件，不走 .so 优先搜索
#
# 顺序（左依赖右，被依赖者放右边）：
#   ssl       → crypto
#   readline  → history → tinfo
#   icui18n   → icuuc → icudata
#   z
#   ossp-uuid (ossp, 独立) — .a 文件叫 libossp-uuid.a
#   xml2      → iconv
#   pgcommon, pgport (postgresql 自己的内部库)
#   android-shmem, log (termux 必需)
#
# 系统库 (-ldl -lpthread -lm) 走动态，因为它们本来就是 .so
# ============================================================
TERMUX_PKG_EXTRA_MAKE_ARGS='LIBS=-lpgcommon -lpgport -l:libssl.a -l:libcrypto.a -l:libreadline.a -l:libhistory.a -l:libtinfo.a -l:libicui18n.a -l:libicuuc.a -l:libicudata.a -l:libz.a -l:libossp-uuid.a -l:libxml2.a -l:libiconv.a -landroid-shmem -llog -ldl -lpthread -lm'

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
