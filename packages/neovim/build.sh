TERMUX_PKG_HOMEPAGE=https://neovim.io/
TERMUX_PKG_DESCRIPTION="Ambitious Vim-fork focused on extensibility and agility (nvim)"
TERMUX_PKG_LICENSE="Apache-2.0, VIM License"
TERMUX_PKG_LICENSE_FILE="LICENSE.txt"
TERMUX_PKG_MAINTAINER="Joshua Kahn <tom@termux.dev>"
TERMUX_PKG_VERSION="0.12.3"
TERMUX_PKG_REVISION=1
TERMUX_PKG_SRCURL="https://github.com/neovim/neovim/archive/refs/tags/v${TERMUX_PKG_VERSION}.tar.gz"
TERMUX_PKG_SHA256=36a6c66bfbba5d96fa512110aecddb981148a4d013b5ecd01a42877c49855a41

# 运行时仅保留 libandroid-support (shim 脚本可能需要) 和 tree-sitter-parsers (动态加载的语法解析器)
TERMUX_PKG_DEPENDS="libandroid-support, tree-sitter-parsers"

# 构建时增加所有依赖的 -static 包，确保有 .a 文件可用
TERMUX_PKG_BUILD_DEPENDS="libandroid-support-static, libiconv-static, libmsgpack-static, libunibilium-static, libuv-static, libvterm-static, lua51-lpeg-static, luajit-static, luv-static, tree-sitter-static, utf8proc-static"

TERMUX_PKG_BREAKS="neovim-nightly"
TERMUX_PKG_CONFLICTS="neovim-nightly"
TERMUX_PKG_HOSTBUILD=true
TERMUX_PKG_CONFFILES="share/nvim/sysinit.vim"
TERMUX_PKG_AUTO_UPDATE=true
TERMUX_PKG_UPDATE_VERSION_REGEXP="\d+\.\d+\.\d+"

TERMUX_PKG_EXTRA_CONFIGURE_ARGS="
-DLUAJIT_INCLUDE_DIR=$TERMUX_PREFIX/include/luajit-2.1
-DLPEG_LIBRARY=$TERMUX_PREFIX/lib/liblpeg-5.1.a
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

    # Copy away host-built libnlua0.so for use as -DNLUA0_HOST_PRG
    cp -vf ./build/lib/libnlua0.so "$TERMUX_PKG_HOSTBUILD_DIR/"

    # Copy away host-built nvim for use as -DNVIM_HOST_PRG
    cp -vf ./build/bin/nvim "$TERMUX_PKG_HOSTBUILD_DIR/"

    make distclean
    rm -Rf build/
}

termux_step_pre_configure() {
    # 隐藏依赖库的动态库，强制 CMake 链接静态库 (.a)
    local _libs=(
        "libmsgpack"
        "libmsgpack-c"
        "libunibilium"
        "libuv"
        "libvterm"
        "libluv"
        "libtree-sitter"
        "libutf8proc"
        "libiconv"
        "libluajit-5.1"
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
    # 恢复隐藏的动态库
    cd "$TERMUX_PREFIX/lib"
    for lib in libmsgpack libmsgpack-c libunibilium libuv libvterm libluv libtree-sitter libutf8proc libiconv libluajit-5.1 libandroid-support; do
        for f in ${lib}.so*.bak; do
            if [ -e "$f" ] || [ -L "$f" ]; then
                mv "$f" "${f%.bak}"
            fi
        done
    done

    # 打印二进制依赖，方便验证是否成功静态链接
    echo "========== NVIM BINARY DEPENDENCIES =========="
    ${READELF:-readelf} -d "$TERMUX_PREFIX/libexec/nvim/nvim" || true
    echo "=============================================="

    local _CONFIG_DIR=$TERMUX_PREFIX/share/nvim
    mkdir -p "$_CONFIG_DIR"

    # Tree-sitter grammars are packaged separately and installed into TERMUX_PREFIX/lib/tree_sitter.
    rm -f "${TERMUX_PREFIX}"/share/nvim/runtime/parser
    ln -sf "${TERMUX_PREFIX}"/lib/tree_sitter "${TERMUX_PREFIX}"/share/nvim/runtime/parser

    # Move the `nvim` binary to $PREFIX/libexec
    # and replace it with our LD_PRELOAD shim.
    # See: packages/neovim/nvim-shim.sh for details.
    mkdir -p "$TERMUX_PREFIX/libexec/nvim"
    mv "${TERMUX_PREFIX}"/bin/nvim "${TERMUX_PREFIX}"/libexec/nvim
    sed -e "s|@TERMUX_PREFIX@|${TERMUX_PREFIX}|g" \
        "$TERMUX_PKG_BUILDER_DIR/nvim-shim.sh" \
        > "${TERMUX_PREFIX}/bin/nvim"
    chmod 700 "${TERMUX_PREFIX}/bin/nvim"

    # Add termux specific configuration
    sed -e "s|@TERMUX_PREFIX@|${TERMUX_PREFIX}|g" \
        "$TERMUX_PKG_BUILDER_DIR/sysinit.vim" \
        > "$_CONFIG_DIR/sysinit.vim"

    { # Set up a wrapper script for `ex` to be called by `update-alternatives`
        echo "#!$TERMUX_PREFIX/bin/sh"
        echo "exec \"$TERMUX_PREFIX/bin/nvim\" -e \"\$@\""
    } > "$TERMUX_PREFIX/libexec/nvim/ex"

    { # Set up a wrapper script for `view` to be called by `update-alternatives`
        echo "#!$TERMUX_PREFIX/bin/sh"
        echo "exec \"$TERMUX_PREFIX/bin/nvim\" -R \"\$@\""
    } > "$TERMUX_PREFIX/libexec/nvim/view"

    { # Set up a wrapper script for `vimdiff` to be called by `update-alternatives`
        echo "#!$TERMUX_PREFIX/bin/sh"
        echo "exec \"$TERMUX_PREFIX/bin/nvim\" -d \"\$@\""
    } > "$TERMUX_PREFIX/libexec/nvim/vimdiff"

    { # Set up a wrapper script for `vimtutor` to be called by `update-alternatives`
        echo "#!$TERMUX_PREFIX/bin/sh"
        echo "exec \"$TERMUX_PREFIX/bin/nvim\" +Tutor \"\$@\""
    } > "$TERMUX_PREFIX/libexec/nvim/vimtutor"
    chmod 700 "$TERMUX_PREFIX/libexec/nvim/"{ex,view,vimdiff,vimtutor}
}
