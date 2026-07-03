TERMUX_PKG_HOMEPAGE=https://www.nano-editor.org/
TERMUX_PKG_DESCRIPTION="Small, free and friendly text editor"
TERMUX_PKG_LICENSE="GPL-3.0"
TERMUX_PKG_MAINTAINER="@termux"
TERMUX_PKG_VERSION="9.1"
TERMUX_PKG_SRCURL=https://nano-editor.org/dist/latest/nano-$TERMUX_PKG_VERSION.tar.xz
TERMUX_PKG_SHA256=5f47764274cb7532349ce0aa20ec10f1e8e851a6e9fa3eb66812c43d196db042
TERMUX_PKG_AUTO_UPDATE=true
# 运行时不再依赖 ncurses 的 .so（已静态链接进二进制），只留 libandroid-support
TERMUX_PKG_DEPENDS="libandroid-support"
# 构建时需要 ncurses 的静态库（.a）
TERMUX_PKG_BUILD_DEPENDS="ncurses-static"
TERMUX_PKG_EXTRA_CONFIGURE_ARGS="
ac_cv_header_glob_h=no
ac_cv_header_pwd_h=no
gl_cv_func_strcasecmp_works=yes
--disable-libmagic
--enable-utf8
--with-wordbounds
"
# 强制把 ncursesw 静态链接进二进制，libc/libm 等系统库仍走动态链接
TERMUX_PKG_EXTRA_LDFLAGS+=" -l:libncursesw.a"

TERMUX_PKG_CONFFILES="etc/nanorc"
TERMUX_PKG_RM_AFTER_INSTALL="bin/rnano share/man/man1/rnano.1 share/nano/man-html"

termux_step_post_make_install() {
	# Configure nano to use syntax highlighting:
	NANORC=$TERMUX_PREFIX/etc/nanorc
	echo "include \"$TERMUX_PREFIX/share/nano/*nanorc\"" > "$NANORC"
}
