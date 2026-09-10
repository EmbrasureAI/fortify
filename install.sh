#!/bin/sh
set -eu

repository="${FORTIFY_REPOSITORY-${EMBRASURE_REPOSITORY:-EmbrasureAI/fortify}}"
version="${FORTIFY_VERSION-${EMBRASURE_VERSION:-}}"
if [ -z "$version" ]; then
  version="$(curl -fsSL -H 'Accept: application/vnd.github+json' -H 'User-Agent: fortify-installer' "https://api.github.com/repos/${repository}/releases/latest" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -n 1)"
fi
if [ -z "$version" ]; then
  echo "fortify: could not determine the latest release" >&2
  exit 1
fi
version="${version#v}"

case "$(uname -s):$(uname -m)" in
  Darwin:x86_64) target="x86_64-apple-darwin" ;;
  Darwin:arm64) target="aarch64-apple-darwin" ;;
  Linux:x86_64) target="x86_64-unknown-linux-gnu" ;;
  Linux:aarch64|Linux:arm64) target="aarch64-unknown-linux-gnu" ;;
  *) echo "fortify: unsupported platform $(uname -s)/$(uname -m)" >&2; exit 1 ;;
esac

# Historical releases only contain the Embrasure layout.
case "$version" in
  0.[0-5].*) product="embrasure" ;;
  *) product="fortify" ;;
esac
archive="${product}-${version}-${target}.tar.gz"
base="https://github.com/${repository}/releases/download/v${version}"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/fortify-install.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
curl -fsSL "${base}/${archive}" -o "${temporary}/${archive}"
curl -fsSL "${base}/SHA256SUMS" -o "${temporary}/SHA256SUMS"
expected="$(awk -v name="$archive" '$2 == name { print $1 }' "${temporary}/SHA256SUMS")"
if [ -z "$expected" ]; then
  echo "fortify: release checksum is missing for ${archive}" >&2
  exit 1
fi
if command -v shasum >/dev/null 2>&1; then
  actual="$(shasum -a 256 "${temporary}/${archive}" | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "${temporary}/${archive}" | awk '{print $1}')"
else
  echo "fortify: shasum or sha256sum is required" >&2
  exit 1
fi
if [ "$actual" != "$expected" ]; then
  echo "fortify: checksum verification failed for ${archive}" >&2
  exit 1
fi
tar -xzf "${temporary}/${archive}" -C "$temporary"
package="${temporary}/${product}-${version}-${target}"

if [ "${FORTIFY_INSTALL_DIR+x}" = x ]; then
  install_dir="$FORTIFY_INSTALL_DIR"
elif [ -n "${EMBRASURE_INSTALL_DIR:-}" ]; then
  install_dir="$EMBRASURE_INSTALL_DIR"
elif [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
  install_dir="/usr/local/bin"
else
  install_dir="${HOME}/.local/bin"
fi
mkdir -p "$install_dir"

set -- "${package}"/python/sqlglot-*.whl
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
  echo "fortify: bundled SQLGlot package is missing or ambiguous" >&2
  exit 1
fi
bundled_wheel="$1"

python_dir="${install_dir}/.fortify/python"
mkdir -p "$python_dir"
for old_wheel in "${python_dir}"/sqlglot-*.whl; do
  [ -e "$old_wheel" ] && rm "$old_wheel"
done
install -m 644 "$bundled_wheel" "$python_dir/"
# Preserve the legacy Python location for pinned pre-Fortify executables.
legacy_python_dir="${install_dir}/.embrasure/python"
mkdir -p "$legacy_python_dir"
for old_wheel in "${legacy_python_dir}"/sqlglot-*.whl; do
  [ -e "$old_wheel" ] && rm "$old_wheel"
done
install -m 644 "$bundled_wheel" "$legacy_python_dir/"
install -m 755 "${package}/${product}" "${install_dir}/fortify"
install -m 755 "${package}/${product}" "${install_dir}/embrasure"
echo "Installed Fortify ${version} to ${install_dir}/fortify (also available as embrasure)"

case ":${PATH}:" in
  *":${install_dir}:"*) ;;
  *) echo "Add ${install_dir} to PATH before running fortify." >&2 ;;
esac
