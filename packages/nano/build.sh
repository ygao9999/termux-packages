TERMUX_PKG_HOMEPAGE=https://www.nano-editor.org/
TERMUX_PKG_DESCRIPTION="Small, free and friendly text editor"
TERMUX_PKG_LICENSE="GPL-3.0"
TERMUX_PKG_MAINTAINER="@termux"
TERMUX_PKG_VERSION="9.1"
TERMUX_PKG_SRCURL=https://nano-editor.org/dist/latest/nano-$TERMUX_PKG_VERSION.tar.xz
TERMUX_PKG_SHA256=5f47764274cb7532349ce0aa20ec10f1e8e851a6e9fa3eb66812c43d196db042
TERMUX_PKG_AUTO_UPDATE=true
# 运行时完全独立，无任何第三方 .so 依赖 (无需写 TERMUX_PKG_DEPENDS)
# 构建时需要 ncurses 和 libandroid-support 的静态库（.a）
TERMUX_PKG_BUILD_DEPENDS="ncurses-static, libandroid-support-static"
TERMUX_PKG_EXTRA_CONFIGURE_ARGS="
ac_cv_header_glob_h=no
ac_cv_header_pwd_h=no
gl_cv_func_strcasecmp_works=yes
--disable-libmagic
--enable-utf8
--with-wordbounds
"

TERMUX_PKG_CONFFILES="etc/nanorc"
TERMUX_PKG_RM_AFTER_INSTALL="bin/rnano share/man/man1/rnano.1 share/nano/man-html"

termux_step_pre_configure() {
    # 彻底隐藏所有 ncursesw 和 libandroid-support 动态库，迫使链接器只能使用静态库 (.a)
    cd "$TERMUX_PREFIX/lib"
    for f in libncursesw.so* libandroid-support.so*; do
        if [ -e "$f" ] || [ -L "$f" ]; then
            mv "$f" "${f}.bak"
        fi
    done
}

termux_step_post_make_install() {
    # 恢复被隐藏的动态库，以免影响构建环境中的其他包
    cd "$TERMUX_PREFIX/lib"
    for f in libncursesw.so*.bak libandroid-support.so*.bak; do
        if [ -e "$f" ] || [ -L "$f" ]; then
            mv "$f" "${f%.bak}"
        fi
    done

    # Configure nano to use syntax highlighting:
    NANORC=$TERMUX_PREFIX/etc/nanorc
    echo "include \"$TERMUX_PREFIX/share/nano/*nanorc\"" > "$NANORC"
}
