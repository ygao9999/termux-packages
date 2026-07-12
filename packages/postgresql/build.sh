# ============================================================
# postgresql build.sh  (termux-packages framework, 18.2 baseline)
#
# ⚠️ 构建前置：libxml2-static 是手动 build 的（官方仓库没有这个包）
#   在跑本脚本前必须先手动安装上传的 deb：
#     dpkg -i libxml2-static_2.15.3-2_aarch64.deb
#   验证 libxml2.a 在位：
#     ls $TERMUX_PREFIX/lib/libxml2.a
#     nm $TERMUX_PREFIX/lib/libxml2.a | grep 'U libiconv'
#     （应看到 U libiconv / libiconv_open / libiconv_close）
#   这三个 U 符号由 libiconv-static（官方包）提供，所以 BUILD_DEPENDS
#   里也加了 libiconv-static。
#
# 4 条核心改动：
#   1. TERMUX_PKG_BUILD_DEPENDS  → 8 个 -static 子包
#      （openssl / readline / icu / zlib / uuid / xml2 / ncurses / iconv，
#       构建期需要，最终静态链接进二进制，运行时不依赖 .so）
#   2. --with-uuid=e2fs  →  --with-uuid=ossp
#      对齐 ossp-uuid-static（ossp 装的是 <uuid.h>，
#      e2fsprogs 的 libuuid 装的是 <uuid/uuid.h>，header 路径不同）
#   3. termux_step_pre_configure 里加 LIBS 做部分静态链接
#      -Wl,-Bstatic ... -Wl,-Bdynamic，放 LIBS 不放 LDFLAGS
#      （重演之前 LDFLAGS 位置错误导致探测失败的坑）
#   4. 旧版手工 find .a / wget 的 termux_step_post_configure 已删
#      （官方 18.2 baseline 本来就没有，无需再处理）
#
# 保留官方 18.2 的全部 Android-only 关键配置：
#   - USE_UNNAMED_POSIX_SEMAPHORES=1   (Android 无 SysV 信号量)
#   - ZIC=hostbuilt zic                (Android 6.0+ 不支持 hard link)
#   - pgac_cv_prog_cc_LDFLAGS_EX_BE__Wl___export_dynamic=yes
#     (PG16+ initdb "cannot locate symbol" 修复)
#   - pgac_cv_prog_cc_LDFLAGS__Wl___as_needed=yes
#   - on-device build check
#   - contrib 模块批量编译（17 个，含 uuid-ossp）
#   - postgres service script
# ============================================================

TERMUX_PKG_HOMEPAGE=https://www.postgresql.org
TERMUX_PKG_DESCRIPTION="Object-relational SQL database"
TERMUX_PKG_LICENSE="PostgreSQL"
TERMUX_PKG_LICENSE_FILE="COPYRIGHT"
TERMUX_PKG_MAINTAINER="@termux"
TERMUX_PKG_VERSION="18.2"
TERMUX_PKG_SRCURL=https://ftp.postgresql.org/pub/source/v$TERMUX_PKG_VERSION/postgresql-$TERMUX_PKG_VERSION.tar.bz2
TERMUX_PKG_SHA256=5245bd1b79700d55b8e0575be0325ef61e7bbef627e6a616e4cf36ad4687be36

# ============================================================
# 依赖划分策略：
#   8 个核心库 → 全部静态链接进二进制（构建期用 -static 子包的 .a）
#   其它库     → 动态依赖，用户 pkg install postgresql 时自动拉
#
# 验证依据（实测 .deb 解包）：
#   readline-static (8.3.3) 只含 libreadline.a + libhistory.a；
#     libreadline.a 里有 U tgetent/tgetstr/tputs 等 undefined 符号。
#   ncurses-static (6.6.20260307+really6.5.20250830) 含 libncursesw.a
#     (771KB / 169 个 .o)，并附带 libtinfo.a 作为 symlink → libncursesw.a。
#     → 必须把 ncurses-static 加进静态段才能完全消除 tgetent 等 U 符号。
#   libxml2-static (2.15.3-2，手动 build) 含 libxml2.a (7.6MB)，
#     有 U libiconv/libiconv_open/libiconv_close 三个 undefined 符号。
#   libiconv-static (1.18-1) 含 libiconv.a (1.16MB)，T libiconv/open/close。
#     → 必须把 libiconv-static 加进静态段才能完全消除 libxml2 的 U 符号。
# ============================================================

# 构建期依赖：8 个静态库子包 + 编译工具
#
# 重要：termux-packages 的 -i/-I 参数只对 TERMUX_PKG_DEPENDS（运行期依赖）
# 生效，不覆盖 TERMUX_PKG_BUILD_DEPENDS（构建期依赖）——后者即使官方仓库
# 已有预编译 .deb，也会被 build-package.sh 强制走本地源码编译一次。
#
# flex 在这个环境（较新版本 gcc/clang）下源码编译会在 gnulib 的 malloc.c
# 兼容层报错（"too many arguments to function malloc"）。这是 flex 自带
# gnulib 代码与新编译器内建函数原型不匹配导致的已知问题，与本项目改动
# 无关，见 CI workflow 里对应的处理步骤（提前在 output/ 放一份能通过
# 编译的 flex .deb，或直接给 flex 单独跑一次带兼容 CFLAGS 的构建）。
TERMUX_PKG_BUILD_DEPENDS="openssl-static, readline-static, libicu-static, zlib-static, ossp-uuid-static, libxml2-static, ncurses-static, libiconv-static"



# 运行期动态依赖（用户 pkg install 时会被 termux 自动拉取）：
#   libandroid-execinfo        → backtrace() 系列（Android libc 缺失）
#   libandroid-shmem           → shm_open/shm_unlink（PG 共享内存需要）
#   libandroid-posix-semaphore → POSIX named semaphore 支持（sem_open/
#                                sem_close/sem_unlink）。注意本配方用了
#                                USE_UNNAMED_POSIX_SEMAPHORES=1，理论上
#                                postgres 自身不需要 named semaphore，但
#                                保留这个依赖以防某个 contrib 模块或链接
#                                探测阶段仍引用了这些符号。若确认完全用
#                                不到，可以安全删除这一项。
# 注意：ncurses 已从运行期依赖中移除，因为 libncursesw.a 已静态链接进二进制
TERMUX_PKG_DEPENDS="libandroid-execinfo, libandroid-shmem, libandroid-posix-semaphore"

# ----- configure args -----
# 改动 #2: --with-uuid=ossp 替代 --with-uuid=e2fs
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

# ------------------------------------------------------------
# host build：官方做法是 configure + make -j 全树，
# 真正目的是拿到 patched 的 zic（用 symlink 替代 hard link）。
# ------------------------------------------------------------
termux_step_host_build() {
    # Build a native zic binary which we have patched to
    # use symlinks instead of hard links.
    $TERMUX_PKG_SRCDIR/configure --without-readline
    make -j "${TERMUX_PKG_MAKE_PROCESSES}"
}

# ------------------------------------------------------------
# pre_configure：改动 #3 在这里加 LIBS，保留官方的 on-device 检查。
# ------------------------------------------------------------
termux_step_pre_configure() {
    # 官方的 on-device 安全检查（删 TERMUX_PREFIX 里的文件会出问题）
    if $TERMUX_ON_DEVICE_BUILD; then
        termux_error_exit "Package '$TERMUX_PKG_NAME' is not safe for on-device builds."
    fi

    # 部分静态链接：8 个 .a 全部 -Bstatic，
    # 之后立刻 -Bdynamic 切回，让系统库走动态
    #
    # 依赖方向（左依赖右，被依赖者放右边）：
    #   ssl       → crypto
    #   readline  → history → tinfo
    #   icui18n   → icuuc → icudata
    #   z
    #   uuid      (ossp, 独立)
    #   xml2      → iconv（libxml2.a 有 U libiconv*）
    #   tinfo     (= libncursesw.a，提供 tgetent/tgetstr/tputs)
    #
    # 动态段：
    #   -ldl -lpthread -lm  : openssl/icu 等系统库
    #   (ncurses/iconv 已静态进二进制，运行时不再需要 .so)
    #
    # 为什么放 LIBS 而不是 LDFLAGS：
    #   configure 的 feature 探测走 AC_CHECK_LIB 等宏，会直接把
    #   $LIBS 拼到测试链接命令里。LDFLAGS 放 -lssl 时 gcc 会把
    #   "-lssl" 当 ld 选项解析，找不到对应 .so 就 silently skip，
    #   导致 HAVE_LIBSSL 探测失败 → 编译出来的 postgresql 没加密。
    export LIBS="-Wl,-Bstatic \
        -lssl -lcrypto \
        -lreadline -lhistory -ltinfo \
        -licui18n -licuuc -licudata \
        -lz \
        -luuid \
        -lxml2 -liconv \
        -Wl,-Bdynamic \
        -ldl -lpthread -lm \
        $LIBS"
}

# ------------------------------------------------------------
# post_make_install：保留官方逻辑
#   1. 装 man 页
#   2. 批量编译 17 个 contrib 模块（含 uuid-ossp，因为 --with-uuid=ossp）
# ------------------------------------------------------------
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