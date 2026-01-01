#!/usr/bin/env bash
set -euo pipefail

DEBS_DIR="/debs"
BUILD_DIR="/build"

mkdir -p "$DEBS_DIR" "$BUILD_DIR"
cd "$BUILD_DIR"

# ------------------------------------------------------------
# CPAN modules
# ------------------------------------------------------------
CPAN_MODULES=(
	"Math::Random::Secure"
	"Statistics::Basic"
	"Time::Format"
	"JSON::Create"
	"Redis"
	"File::chown"
	"Test2::V0"
	"Test::Deep"
	"Math::Random::ISAAC"
	"Crypt::Random::Source::Factory"
	"JSON::Create"
	"IO::Socket::Timeout"
	"Module::Find"
	"PerlIO::via::Timeout"
	"Number::Format"
	"Exporter::Tiny"
	"Type::Tiny"
	"Types::Standard"
)

echo "Building CPAN modules..."
for mod in "${CPAN_MODULES[@]}"; do
	build_flag="${DEBS_DIR}/${mod}.built"

	if [[ -f "$build_flag" ]]; then
		echo "$mod already built, skipping."
		continue
	fi

	echo "Building $mod..."
	dh-make-perl --build --cpan "$mod" --notest
	mv *.deb "$DEBS_DIR/"
	touch "$build_flag"
done

# ------------------------------------------------------------
# GitHub modules
# ------------------------------------------------------------
GITHUB_MODULES=(
	"https://github.com/st0ff3r/Net-MQTT-Simple.git master 0.75"
	"https://github.com/DCIT/perl-CryptX.git 6cef046ba02cfd01d1bfbe9e3f914bb7d1a03489 0.087"
)

echo "Building GitHub modules..."
for entry in "${GITHUB_MODULES[@]}"; do
	repo_url=$(echo "$entry" | cut -d' ' -f1)
	commit_hash=$(echo "$entry" | cut -d' ' -f2)
	pkg_version=$(echo "$entry" | cut -d' ' -f3)
	mod_name=$(basename "$repo_url" .git)
	pkg_name="lib$(echo "$mod_name" | tr '[:upper:]' '[:lower:]')-perl"
	build_flag="${DEBS_DIR}/${mod_name}.built"

	if [[ -f "$build_flag" ]]; then
		echo "$mod_name already built, skipping."
		continue
	fi

	echo "Building $mod_name..."
	rm -rf "$mod_name"
	git clone "$repo_url"
	cd "$mod_name"
	git checkout "$commit_hash"

	perl Makefile.PL
	make
	# Optional: make test

	DESTDIR=$(pwd)/../${mod_name}_install
	rm -rf "$DESTDIR"
	make install DESTDIR="$DESTDIR"

	PKG_DIR=$(pwd)/../${pkg_name}_${pkg_version}_all
	rm -rf "$PKG_DIR"
	mkdir -p "$PKG_DIR/DEBIAN"
	mkdir -p "$PKG_DIR/usr/local"

	echo "Package: $pkg_name
Version: $pkg_version
Architecture: all
Maintainer: Your Name <you@example.com>
Description: $mod_name Perl module built from Git" > "$PKG_DIR/DEBIAN/control"

	cp -r "$DESTDIR"/* "$PKG_DIR/"
	dpkg-deb --build "$PKG_DIR" "/debs/${pkg_name}_${pkg_version}_all.deb"

	touch "$build_flag"

	cd "$BUILD_DIR"
	rm -rf "$mod_name" "$DESTDIR" "$PKG_DIR"
done

echo "All packages built or already present in $DEBS_DIR."

# Generates a Packages.gz file for APT to use.
cd /debs
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz

echo "Made a Packages.gz file for APT to use"
