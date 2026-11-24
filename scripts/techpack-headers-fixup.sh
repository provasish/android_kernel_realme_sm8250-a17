#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# headers_install exports each techpack's uapi headers to
# <dst>/<name>/include/uapi, but the QTI userspace (audio HAL, display, ...)
# looks for them in <dst>/techpack/<name>/include and <dst>/include/<name>.
# Expose them in both places.
#
# usage: techpack-headers-fixup.sh <INSTALL_HDR_PATH>

dst="$1"
[ -d "$dst" ] || exit 0

for tp in "$dst"/*/include/uapi; do
	[ -d "$tp" ] || continue
	name=$(basename "$(dirname "$(dirname "$tp")")")

	mkdir -p "$dst/techpack/$name/include" || exit 1
	cp -a "$tp"/. "$dst/techpack/$name/include/" || exit 1

	# Don't shadow the stock headers of the same name (e.g. include/video)
	if [ ! -e "$dst/include/$name" ]; then
		mkdir -p "$dst/include/$name" || exit 1
		cp -a "$tp"/. "$dst/include/$name/" || exit 1
	fi
done
