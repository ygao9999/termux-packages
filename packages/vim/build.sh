# shellcheck shell=bash
TERMUX_PKG_HOMEPAGE=https://www.vim.org
TERMUX_PKG_DESCRIPTION="Vi IMproved - enhanced vi editor"
TERMUX_PKG_LICENSE="VIM License"
TERMUX_PKG_MAINTAINER="Joshua Kahn <tom@termux.dev>"
TERMUX_PKG_BUILD_DEPENDS="luajit, perl, python, ruby, tcl"
TERMUX_PKG_SUGGESTS="luajit, perl, python, ruby, tcl"
TERMUX_PKG_CONFLICTS="vim-gtk"
TERMUX_PKG_BREAKS="vim-python, vim-runtime"
TERMUX_PKG_REPLACES="vim-python, vim-runtime"
TERMUX_PKG_PROVIDES="vim-python"
TERMUX_PKG_VERSION="9.2.0750"
TERMUX_PKG_SRCURL="https://github.com/vim/vim/archive/refs/tags/v${TERMUX_PKG_VERSION}.tar.gz"
TERMUX_PKG_SHA256=7d460830e12082b541c34b0b96942ebface1ad9fa0b77245930717c0ccf8b664
TERMUX_PKG_BUILD_IN_SRC=true
TERMUX_PKG_CONFFILES="share/vim/vimrc"
TERMUX_PKG_EXTRA_CONFIGURE_ARGS="
vim_cv_getcwd_broken=no
vim_cv_memmove_handles_overlap=yes
vim_cv_stat_ignores_slash=no
vim_cv_terminfo=yes
vim_cv_tgetent=zero
vim_cv_toupper_broken=no
vim_cv_tty_group=world
ac_cv_small_wchar_t=no
--with-features=huge
--enable-netbeans=no
--with-tlib=ncursesw
--enable-multibyte
--with-compiledby=Termux-static
--enable-fail-if-missing=yes
--enable-python3interp=dynamic
--with-python3-config-dir=$TERMUX_PYTHON_HOME/config-${TERMUX_PYTHON_VERSION}-${TERMUX_HOST_PLATFORM}/
vi_cv_path_python3_pfx=$TERMUX_PREFIX
vi_cv_path_python3_include=${TERMUX_PREFIX}/include/python${TERMUX_PYTHON_VERSION}
vi_cv_path_python3_platinclude=${TERMUX_PREFIX}/include/python${TERMUX_PYTHON_VERSION}
vi_cv_var_python3_abiflags=
vi_cv_var_python3_version=${TERMUX_PYTHON_VERSION}
--enable-luainterp=dynamic
--with-lua-prefix=$TERMUX_PREFIX
--with-luajit
--enable-perlinterp=dynamic
--with-xsubpp=$TERMUX_PREFIX/bin/xsubpp
--enable-rubyinterp=dynamic
--enable-tclinterp=dynamic
--enable-gui=no
--without-x
"
TERMUX_PKG_AUTO_UPDATE=true
TERMUX_PKG_UPDATE_TAG_TYPE="newest-tag"

# 静态依赖库版本,和 termux-packages 仓库里对应 package 的版本保持一致
_STATIC_NCURSES_VERSION="6.5"
_STATIC_LIBICONV_VERSION="1.17"
_STATIC_LIBSODIUM_VERSION="1.0.20"

# ============================================================================
# 兜底环境变量
# ----------------------------------------------------------------------------
# Termux 的标准 build pipeline(CC/CXX/CFLAGS/TERMUX_MAKE_PROCESSES 等)是在
# termux_step_start_build / termux_step_setup_toolchain 之后才赋值的。
# 我们这个 _termux_build_static_dep 可能在更早的时机被调用,所以统一兜底,
# 避免在 set -u 下出现 "unbound variable" fatal。
# ============================================================================
_termux_static_dep_init_env() {
    : "${TERMUX_PREFIX:=/data/data/com.termux/files/usr}"
    : "${TERMUX_HOST_PLATFORM:=$(dpkg-architecture -qDEB_HOST_GNU_TYPE 2>/dev/null || echo aarch64-linux-android)}"
    : "${TERMUX_PKG_TMPDIR:=/tmp/termux-build}"
    : "${TERMUX_MAKE_PROCESSES:=$(nproc 2>/dev/null || echo 4)}"
    : "${CC:=clang}"
    : "${CXX:=clang++}"
    : "${CFLAGS:=-O2 -fPIC}"
    : "${LDFLAGS:=}"
    : "${AR:=llvm-ar}"
    : "${RANLIB:=llvm-ranlib}"
    export TERMUX_PREFIX TERMUX_HOST_PLATFORM TERMUX_PKG_TMPDIR \
           TERMUX_MAKE_PROCESSES CC CXX CFLAGS LDFLAGS AR RANLIB
}

# ============================================================================
# 通用静态依赖构建函数
# ----------------------------------------------------------------------------
# 用法:
#   _termux_build_static_dep <name> <url> <extra_configure...>
# extra_configure 以剩余参数形式传入, 避免字符串 word-splitting 问题。
# ============================================================================
_termux_build_static_dep() {
    local name="$1"
    local url="$2"
    shift 2
    local -a extra_configure=("$@")

    local build_root="${TERMUX_PKG_TMPDIR}/static-deps/${name}"
    local destdir="${TERMUX_PKG_TMPDIR}/static-deps/${name}-root"

    _termux_static_dep_init_env

    mkdir -p "${build_root}"
    rm -rf "${build_root}"/*
    rm -rf "${destdir}"

    (
        cd "${build_root}" || exit 1
        echo "==> [${name}] downloading ${url}"
        curl -fL --retry 3 -o src.tar.gz "${url}"
        tar xf src.tar.gz --strip-components=1

        echo "==> [${name}] configure"
        CC="${CC}" CXX="${CXX}" \
        CFLAGS="${CFLAGS}" CXXFLAGS="${CFLAGS}" LDFLAGS="${LDFLAGS}" \
        AR="${AR}" RANLIB="${RANLIB}" \
        ./configure \
            --host="${TERMUX_HOST_PLATFORM}" \
            --prefix="${TERMUX_PREFIX}" \
            --enable-static \
            --disable-shared \
            "${extra_configure[@]}"

        echo "==> [${name}] make -j${TERMUX_MAKE_PROCESSES}"
        make -j "${TERMUX_MAKE_PROCESSES}"

        echo "==> [${name}] make install to DESTDIR"
        make install "DESTDIR=${destdir}"
    )

    # 合并到 TERMUX_PREFIX, 但不覆盖 termux 已有的 .so / runtime
    # 只拷 .a 和头文件
    mkdir -p "${TERMUX_PREFIX}/lib" \
             "${TERMUX_PREFIX}/include" \
             "${TERMUX_PREFIX}/lib/pkgconfig"

    local f
    while IFS= read -r -d '' f; do
        cp -a "$f" "${TERMUX_PREFIX}/lib/"
    done < <(find "${destdir}${TERMUX_PREFIX}/lib" -maxdepth 1 -name '*.a' -print0 2>/dev/null)

    if [[ -d "${destdir}${TERMUX_PREFIX}/include" ]]; then
        cp -a "${destdir}${TERMUX_PREFIX}/include/." "${TERMUX_PREFIX}/include/"
    fi

    if [[ -d "${destdir}${TERMUX_PREFIX}/lib/pkgconfig" ]]; then
        cp -a "${destdir}${TERMUX_PREFIX}/lib/pkgconfig/." \
              "${TERMUX_PREFIX}/lib/pkgconfig/"
    fi
}

# ============================================================================
# 三个具体静态依赖的入口
# ============================================================================
_termux_build_static_ncurses() {
    _termux_build_static_dep \
        ncurses \
        "https://ftp.gnu.org/gnu/ncurses/ncurses-${_STATIC_NCURSES_VERSION}.tar.gz" \
        --enable-widec \
        --with-default-terminfo-dir="${TERMUX_PREFIX}/share/terminfo" \
        --with-terminfo-dirs="${TERMUX_PREFIX}/share/terminfo:/system/usr/share/terminfo" \
        --enable-pc-files \
        --with-pkg-config-libdir="${TERMUX_PREFIX}/lib/pkgconfig" \
        --without-cxx-binding \
        --without-ada \
        --without-tests \
        --disable-db-install \
        --without-shared \
        --with-normal \
        --with-static
}

_termux_build_static_libiconv() {
    _termux_build_static_dep \
        libiconv \
        "https://ftp.gnu.org/gnu/libiconv/libiconv-${_STATIC_LIBICONV_VERSION}.tar.gz" \
        --disable-nls \
        --without-libiconv-prefix
}

_termux_build_static_libsodium() {
    _termux_build_static_dep \
        libsodium \
        "https://github.com/jedisct1/libsodium/releases/download/${_STATIC_LIBSODIUM_VERSION}-RELEASE/libsodium-${_STATIC_LIBSODIUM_VERSION}.tar.gz" \
        --disable-pie
}

# ============================================================================
# 入口: 在 vim 自身 configure 之前, 把三个静态依赖装好
# ============================================================================
termux_step_pre_configure() {
    _termux_build_static_ncurses
    _termux_build_static_libiconv
    _termux_build_static_libsodium

    # 告诉 vim 的 configure: ncursesw 走静态, 链接 -lncursesw 而不是依赖 .so
    export LDFLAGS="${LDFLAGS} -L${TERMUX_PREFIX}/lib"
    export CPPFLAGS="${CPPFLAGS:-} -I${TERMUX_PREFIX}/include"

    # 让 vim 优先用我们刚装的 pkg-config
    export PKG_CONFIG_PATH="${TERMUX_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
}

# ============================================================================
# auto_update
# ============================================================================
termux_pkg_auto_update() {
    local latest_tag current_patch latest_patch
    latest_tag="$(termux_github_api_get_tag)"
    latest_patch="10#${latest_tag##*.}"
    current_patch="10#${TERMUX_PKG_VERSION##*.}"

    # 注意: (( )) 在结果为 0 时返回非零退出码, set -e 下会让脚本退出。
    # 改用 $(( )) 表达式赋值, 永远返回 0。
    current_patch=$(( current_patch - current_patch % 50 ))
    latest_patch=$(( latest_patch - latest_patch % 50 ))

    if (( current_patch == latest_patch )); then
        echo "INFO: Skipping ${latest_tag#v}, no new 50th patch since $TERMUX_PKG_VERSION."
        return
    fi

    termux_pkg_upgrade_version "$(printf '%s.%04d' "${latest_tag%.*}" "${latest_patch}")"
}
