TERMUX_PKG_HOMEPAGE=https://neovim.io/
TERMUX_PKG_DESCRIPTION="Ambitious Vim-fork focused on extensibility and agility (nvim)"
TERMUX_PKG_LICENSE="Apache-2.0, VIM License"
TERMUX_PKG_LICENSE_FILE="LICENSE.txt"
TERMUX_PKG_MAINTAINER="Joshua Kahn <tom@termux.dev>"
TERMUX_PKG_VERSION="0.12.3"
TERMUX_PKG_REVISION=1
TERMUX_PKG_SRCURL="https://github.com/neovim/neovim/archive/refs/tags/v${TERMUX_PKG_VERSION}.tar.gz"
TERMUX_PKG_SHA256=36a6c66bfbba5d96fa512110aecddb981148a4d013b5ecd01a42877c49855a41

# 依赖原生包，这些包在 Termux 中自带 .a 静态库文件
TERMUX_PKG_DEPENDS="libandroid-support, libiconv, libmsgpack, libunibilium, libuv, libvterm (>= 1:0.3-0), lua51-lpeg, luajit, luv, tree-sitter, tree-sitter-parsers, utf8proc"

TERMUX_PKG_BREAKS="neovim-nightly"
TERMUX_PKG_CONFLICTS="neovim-nightly"
TERMUX_PKG_HOSTBUILD=true
TERMUX_PKG_CONFFILES="share/nvim/sysinit.vim"
TERMUX_PKG_AUTO_UPDATE=true
TERMUX_PKG_UPDATE_VERSION_REGEXP="\d+\.\d+\.\d+"

TERMUX_PKG_EXTRA_CONFIGURE_ARGS="
-DLUAJIT_INCLUDE_DIR=$TERMUX_PREFIX/include/luajit-2.1
-DLPEG_LIBRARY=$TERMUX_PREFIX/lib/liblpeg-5.1.so
-DCOMPILE_LUA=OFF
-DNLUA0_HOST_PRG=$TERMUX_PKG_HOSTBUILD_DIR/libnlua0.so
-DNVIM_HOST_PRG=$TERMUX_PKG_HOSTBUILD_DIR/nvim
"

termux_step_host_build() {
    termux_setup_cmake

    mkdir -p "$TERMUX_PKG_HOSTBUILD_DIR/deps"
    cd "$TERMUX_PKG_HOSTBUILD_DIR/deps" || termux_error_exit "failed to perform host build for nvim"
    cmake "$TERMUX_PKG_SRCDIR/cmake.deps"

    make -j 1

    cd "$TERMUX_PKG_SRCDIR" || termux_error_exit "failed to perform host build for nvim"

    make CMAKE_EXTRA_FLAGS="-DCMAKE_INSTALL_PREFIX=$TERMUX_PKG_HOSTBUILD_DIR -DUSE_BUNDLED_LUAROCKS=ON" install

    cp -vf ./build/lib/libnlua0.so "$TERMUX_PKG_HOSTBUILD_DIR/"
    cp -vf ./build/bin/nvim "$TERMUX_PKG_HOSTBUILD_DIR/"

    make distclean
    rm -Rf build/
}

termux_step_pre_configure() {
    # 1. 强制 CMake 的 find_library 只搜索静态库后缀
    export CMAKE_FIND_LIBRARY_SUFFIXES=".a"
    TERMUX_PKG_EXTRA_CONFIGURE_ARGS+=" -DCMAKE_FIND_LIBRARY_SUFFIXES=.a"

    # 2. 隐藏需要静态链接的核心 C 库的动态库，防止链接器动态链接
    local _libs=(
        "libmsgpack"
        "libmsgpackc"
        "libunibilium"
        "libuv"
        "libvterm"
        "libtree-sitter"
        "libutf8proc"
        "libiconv"
        "libandroid-support"
    )
    
    cd "$TERMUX_PREFIX/lib"
    for lib in "${_libs[@]}"; do
        for f in ${lib}.so*; do
            if [ -e "$f" ] || [ -L "$f" ]; then
                mv "$f" "${f}.bak"
            fi
        done
    done
}

termux_step_post_make_install() {
    # 恢复被隐藏的动态库
    cd "$TERMUX_PREFIX/lib"
    for lib in libmsgpack libmsgpackc libunibilium libuv libvterm libtree-sitter libutf8proc libiconv libandroid-support; do
        for f in ${lib}.so*.bak; do
            if [ -e "$f" ] || [ -L "$f" ]; then
                mv "$f" "${f%.bak}"
            fi
        done
    done

    # 打印二进制依赖，方便验证
    echo "========== NVIM BINARY DEPENDENCIES =========="
    ${READELF:-readelf} -d "$TERMUX_PREFIX/libexec/nvim/nvim" || true
    echo "=============================================="

    local _CONFIG_DIR=$TERMUX_PREFIX/share/nvim
    mkdir -p "$_CONFIG_DIR"

    rm -f "${TERMUX_PREFIX}"/share/nvim/runtime/parser
    ln -sf "${TERMUX_PREFIX}"/lib/tree_sitter "${TERMUX_PREFIX}"/share/nvim/runtime/parser

    mkdir -p "$TERMUX_PREFIX/libexec/nvim"
    mv "${TERMUX_PREFIX}"/bin/nvim "${TERMUX_PREFIX}"/libexec/nvim
    sed -e "s|@TERMUX_PREFIX@|${TERMUX_PREFIX}|g" \
        "$TERMUX_PKG_BUILDER_DIR/nvim-shim.sh" \
        > "${TERMUX_PREFIX}/bin/nvim"
    chmod 700 "${TERMUX_PREFIX}/bin/nvim"

    sed -e "s|@TERMUX_PREFIX@|${TERMUX_PREFIX}|g" \
        "$TERMUX_PKG_BUILDER_DIR/sysinit.vim" \
        > "$_CONFIG_DIR/sysinit.vim"

    { echo "#!$TERMUX_PREFIX/bin/sh"
      echo "exec \"$TERMUX_PREFIX/bin/nvim\" -e \"\$@\""
    } > "$TERMUX_PREFIX/libexec/nvim/ex"

    { echo "#!$TERMUX_PREFIX/bin/sh"
      echo "exec \"$TERMUX_PREFIX/bin/nvim\" -R \"\$@\""
    } > "$TERMUX_PREFIX/libexec/nvim/view"

    { echo "#!$TERMUX_PREFIX/bin/sh"
      echo "exec \"$TERMUX_PREFIX/bin/nvim\" -d \"\$@\""
    } > "$TERMUX_PREFIX/libexec/nvim/vimdiff"

    { echo "#!$TERMUX_PREFIX/bin/sh"
      echo "exec \"$TERMUX_PREFIX/bin/nvim\" +Tutor \"\$@\""
    } > "$TERMUX_PREFIX/libexec/nvim/vimtutor"
    chmod 700 "$TERMUX_PREFIX/libexec/nvim/"{ex,view,vimdiff,vimtutor}
}
