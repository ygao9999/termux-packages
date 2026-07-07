TERMUX_PKG_HOMEPAGE=https://www.vim.org
TERMUX_PKG_DESCRIPTION="Vi IMproved - enhanced vi editor"
TERMUX_PKG_LICENSE="VIM License"
TERMUX_PKG_MAINTAINER="Joshua Kahn <tom@termux.dev>"
#TERMUX_PKG_DEPENDS=""
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
TERMUX_PKG_UPDATE_TAG_TYPE="newest-tag" # Vim doesn't use release tags

# 静态依赖库版本,和 termux-packages 仓库里对应 package 的版本保持一致
_STATIC_NCURSES_VERSION="6.5"
_STATIC_LIBICONV_VERSION="1.17"
_STATIC_LIBSODIUM_VERSION="1.0.20"

termux_pkg_auto_update() {
	# This auto_update function is shared by `vim` and `vim-gtk`
	# If you make changes to one of them,
	# remember to apply that change to the other as well.
	local latest_tag current_patch latest_patch
	latest_tag="$(termux_github_api_get_tag)"
	latest_patch="10#${latest_tag##*.}"
	current_patch="10#${TERMUX_PKG_VERSION##*.}"

	(( current_patch -= current_patch % 50 ))
	((  latest_patch -=  latest_patch % 50 ))

	if (( current_patch == latest_patch )); then
		echo "INFO: Skipping ${latest_tag#v}, no new 50th patch since $TERMUX_PKG_VERSION."
		return
	fi

	termux_pkg_upgrade_version "$(printf '%s.%04d' "${latest_tag%.*}" "${latest_patch}")"
}

# 在容器内下载并静态编译 ncurses/libiconv/libsodium,产物安装到临时 DESTDIR,
# 再把 .a 和头文件拷进 TERMUX_PREFIX,供后面 vim 自身的 configure/make 使用。
_termux_build_static_dep() {
	local name="$1" url="$2" extra_configure="$3"
	local build_root="${TERMUX_PKG_TMPDIR}/static-deps/${name}"
	local destdir="${TERMUX_PKG_TMPDIR}/static-deps/${name}-root"

	mkdir -p "${build_root}"
	( cd "${build_root}"
	  curl -fL -o src.tar.gz "${url}"
	  tar xf src.tar.gz --strip-components=1
	  CC="${CC}" CXX="${CXX}" CFLAGS="${CFLAGS}" LDFLAGS="${LDFLAGS}" \
	  ./configure --host="${TERMUX_HOST_PLATFORM}" --prefix="${TERMUX_PREFIX}" \
	      --enable-static --disable-shared ${extra_configure}
	  make -j "${TERMUX_MAKE_PROCESSES}"
	  make install DESTDIR="${destdir}" )

	cp -av "${destdir}${TERMUX_PREFIX}"/lib/*.a "${TERMUX_PREFIX}/lib/" 2>/dev/null || true
	cp -av "${destdir}${TERMUX_PREFIX}"/include/. "${TERMUX_PREFIX}/include/" 2>/dev/null || true
}

termux_step_pre_configure() {
	make distclean

	# Remove eventually existing symlinks from previous builds so that they get re-created.
	local -a VIM_BINARIES=('eview' 'evim' 'ex' 'rview' 'rvim' 'view' 'vimdiff')
	for sym in "${VIM_BINARIES[@]}"; do
		rm -f "${TERMUX_PREFIX}/bin/${sym}"
		rm -f "$TERMUX_PREFIX/share/man/man1/${sym}.1"*
	done

	# Vim doesn't support cross-compilation for Perl, Ruby and Tcl
	# out of the box, so we need to patch the configure script to make it work.
	local perl_version ruby_major_version tcl_major_version
	perl_version="$(. "$TERMUX_SCRIPTDIR/packages/perl/build.sh"; echo "${TERMUX_PKG_VERSION[0]}")"
	ruby_major_version="$(. "$TERMUX_SCRIPTDIR/packages/ruby/build.sh"; echo "${TERMUX_PKG_VERSION%\.*}")"
	tcl_major_version="$(. "$TERMUX_SCRIPTDIR/packages/tcl/build.sh"; echo "${TERMUX_PKG_VERSION%\.*}")"

	patch="$TERMUX_PKG_BUILDER_DIR/configure-perl-ruby-tcl-cross-compiling.diff"
	echo "Applying patch: $(basename "$patch")"
	test -f "$patch" && sed \
		-e "s%\@PERL_VERSION\@%${perl_version}%g" \
		-e "s%\@RUBY_MAJOR_VERSION\@%${ruby_major_version}%g" \
		-e "s%\@TCL_MAJOR_VERSION\@%${tcl_major_version}%g" \
		-e "s%\@PERL_PLATFORM\@%${TERMUX_ARCH}-android%g" \
		-e "s%\@RUBY_PLATFORM\@%${TERMUX_HOST_PLATFORM}%g" \
		-e "s%\@TERMUX_PREFIX\@%${TERMUX_PREFIX}%g" \
		"$patch" | patch --silent -p1

	# --- 静态编译 ncurses / libiconv / libsodium,仅这三个库静态化 ---
	# libsodium
	_termux_build_static_dep \
		"libsodium" \
		"https://github.com/jedisct1/libsodium/releases/download/${_STATIC_LIBSODIUM_VERSION}-RELEASE/libsodium-${_STATIC_LIBSODIUM_VERSION}.tar.gz" \
		""

	# libiconv
	_termux_build_static_dep \
		"libiconv" \
		"https://ftp.gnu.org/gnu/libiconv/libiconv-${_STATIC_LIBICONV_VERSION}.tar.gz" \
		""

	# ncurses (widec, 对应 ncursesw)
	_termux_build_static_dep \
		"ncurses" \
		"https://invisible-mirror.net/archives/ncurses/ncurses-${_STATIC_NCURSES_VERSION}.tar.gz" \
		"--without-shared --with-normal --enable-widec --with-termlib"

	# 检查静态库确实生成,避免链接器静默回退到 .so
	local -a STATIC_LIBS=(ncursesw tinfo iconv sodium)
	for lib in "${STATIC_LIBS[@]}"; do
		if [ ! -f "${TERMUX_PREFIX}/lib/lib${lib}.a" ]; then
			echo "ERROR: lib${lib}.a not found in ${TERMUX_PREFIX}/lib — static dependency build failed."
			exit 1
		fi
	done

	# 局部静态链接：只锁定这四个库走 .a,libc/libdl/动态解释器不受影响
	export LDFLAGS="${LDFLAGS} -Wl,-Bstatic -lncursesw -ltinfo -liconv -lsodium -Wl,-Bdynamic"
}

# shellcheck disable=SC2031
termux_step_post_make_install() {
	sed -e "s%\@TERMUX_PREFIX\@%${TERMUX_PREFIX}%g" "$TERMUX_PKG_BUILDER_DIR/vimrc" \
		> "$TERMUX_PREFIX/share/vim/vimrc"

	local _VIM_VERSION="${TERMUX_PKG_VERSION%.*}"
	_VIM_VERSION="${_VIM_VERSION/.}"

	export TERMUX_PKG_RM_AFTER_INSTALL="
	share/vim/vim${_VIM_VERSION}/spell/en.ascii*
	share/vim/vim${_VIM_VERSION}/print
	share/vim/vim${_VIM_VERSION}/tools
	"

	### Remove most tutor files:
	mkdir -p "$TERMUX_PKG_TMPDIR/vim-tutor"
	cp -r   "$TERMUX_PREFIX/share/vim/vim${_VIM_VERSION}/tutor/en/" \
			"$TERMUX_PREFIX/share/vim/vim${_VIM_VERSION}/tutor/tutor.vim" \
			"$TERMUX_PREFIX/share/vim/vim${_VIM_VERSION}/tutor/tutor.tutor"{,.json} \
			"$TERMUX_PREFIX/share/vim/vim${_VIM_VERSION}/tutor/tutor"{1,2} \
			"$TERMUX_PKG_TMPDIR/vim-tutor"
	rm -rf "$TERMUX_PREFIX/share/vim/vim${_VIM_VERSION}/tutor"/*
	cp -r "$TERMUX_PKG_TMPDIR"/vim-tutor/* "$TERMUX_PREFIX/share/vim/vim${_VIM_VERSION}/tutor/"
	mkdir -p "$TERMUX_PREFIX/libexec/vim"
	mv "${TERMUX_PREFIX}"/bin/{ex,view,vim{,diff,tutor}} "${TERMUX_PREFIX}"/libexec/vim
}
