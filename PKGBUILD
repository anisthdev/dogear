# Maintainer: Asif Arbaj <asifarbaj@gmail.com>
_name=dogear
pkgname=totoro-dogear
pkgver=r0
pkgrel=1
pkgdesc="Keyboard-driven ebook reader and library (Qt Quick + foliate-js)"
arch=('x86_64')
url="https://github.com/anisthdev/dogear"
provides=('dogear')
conflicts=('dogear')
license=('unknown')
depends=('qt6-base' 'qt6-declarative' 'qt6-webengine' 'qt6-webchannel' 'libzip')
makedepends=('git' 'cmake' 'ninja' 'qt6-shadertools')
optdepends=('matugen: page and app colours from the wallpaper (~/.config/dogear/colors.css)'
            'sdcv: offline dictionaries (StarDict)')
source=("git+$url.git")
sha256sums=('SKIP')

pkgver() {
    cd "$_name"
    printf "r%s.%s" "$(git rev-list --count HEAD)" "$(git rev-parse --short=7 HEAD)"
}

build() {
    cmake -S "$_name" -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
    cmake --build build
}

package() {
    DESTDIR="$pkgdir" cmake --install build
    # foliate-js and what it vendors are compiled into the binary
    install -Dm644 "$_name/reader/foliate/LICENSE" "$pkgdir/usr/share/licenses/$pkgname/foliate-js"
    install -Dm644 -t "$pkgdir/usr/share/licenses/$pkgname" "$_name/licenses/zip.js" "$_name/licenses/fflate"
}
