#!/usr/bin/env bash
#
# 40 — Download, verify and unpack the Hadoop distribution.
#
#   sudo ./scripts/40-install-hadoop.sh
#
# The checksum step is not ceremony. You are about to run this tarball's shell
# scripts as a privileged service account on every node in a cluster; verify the
# bytes came from Apache.

source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

require_linux
require_root "$@"
require_cmd curl tar sha512sum

TARBALL="hadoop-${HADOOP_VERSION}.tar.gz"
BASE_PATH="hadoop-${HADOOP_VERSION}/${TARBALL}"

mkdir -p "${DOWNLOAD_DIR}"
cd "${DOWNLOAD_DIR}"

download() {
  local url="$1" dest="$2"
  log "GET ${url}"
  # --location follows mirror redirects; --fail turns an HTML 404 page into a
  # non-zero exit instead of a corrupt "tarball".
  curl --fail --location --retry 3 --retry-delay 2 --continue-at - \
       --output "${dest}" "${url}"
}

heading "Fetching Hadoop ${HADOOP_VERSION}"
if [[ -f "${TARBALL}" ]]; then
  skip "${TARBALL} already downloaded"
else
  # downloads.apache.org only carries current releases; older ones move to the
  # archive. Try both before giving up.
  download "${HADOOP_MIRROR}/${BASE_PATH}" "${TARBALL}" \
    || download "${HADOOP_ARCHIVE_MIRROR}/${BASE_PATH}" "${TARBALL}" \
    || die "Could not download ${TARBALL} from either mirror"
  ok "Downloaded ${TARBALL}"
fi

heading "Verifying integrity"
# Always re-fetch the checksum: a cached one next to a cached tarball verifies
# nothing if both were tampered with together.
rm -f "${TARBALL}.sha512"
download "${HADOOP_MIRROR}/${BASE_PATH}.sha512" "${TARBALL}.sha512" \
  || download "${HADOOP_ARCHIVE_MIRROR}/${BASE_PATH}.sha512" "${TARBALL}.sha512" \
  || die "Could not download the SHA-512 checksum — refusing to install unverified bytes"

# Apache publishes two formats depending on release age:
#   "SHA512 (hadoop-x.y.z.tar.gz) = abc..."   (BSD style)
#   "abc...  hadoop-x.y.z.tar.gz"             (coreutils style)
expected="$(tr -d '\n' < "${TARBALL}.sha512" | tr -cd '[:xdigit:]= ()a-zA-Z.\-_' \
            | sed -E 's/.*=[[:space:]]*//; s/[[:space:]].*$//' | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
if [[ ${#expected} -ne 128 ]]; then
  # coreutils style: first field is the digest
  expected="$(awk '{print tolower($1)}' "${TARBALL}.sha512" | head -n1)"
fi
[[ ${#expected} -eq 128 ]] || die "Could not parse a SHA-512 digest from ${TARBALL}.sha512"

actual="$(sha512sum "${TARBALL}" | awk '{print tolower($1)}')"
if [[ "${actual}" != "${expected}" ]]; then
  err "expected ${expected}"
  err "actual   ${actual}"
  die "Checksum mismatch — delete ${DOWNLOAD_DIR}/${TARBALL} and retry"
fi
ok "SHA-512 verified"

heading "Installing to ${HADOOP_HOME}"
if [[ -d "${HADOOP_HOME}" && -x "${HADOOP_HOME}/bin/hadoop" ]]; then
  installed="$("${HADOOP_HOME}/bin/hadoop" version 2>/dev/null | head -n1 | awk '{print $2}')"
  if [[ "${installed}" == "${HADOOP_VERSION}" ]]; then
    skip "Hadoop ${HADOOP_VERSION} already installed at ${HADOOP_HOME}"
  else
    die "${HADOOP_HOME} holds Hadoop ${installed}. Move it aside before installing ${HADOOP_VERSION}; an in-place overwrite mixes two distributions."
  fi
else
  # Unpack beside the target and move into place, so a failed extraction never
  # leaves a half-populated HADOOP_HOME.
  staging="$(mktemp -d "${DOWNLOAD_DIR}/stage.XXXXXX")"
  tar -xzf "${TARBALL}" -C "${staging}"
  mkdir -p "$(dirname "${HADOOP_HOME}")"
  mv "${staging}/hadoop-${HADOOP_VERSION}" "${HADOOP_HOME}"
  rmdir "${staging}"
  ok "Unpacked to ${HADOOP_HOME}"
fi

chown -R "${HADOOP_USER}:${HADOOP_GROUP}" "${HADOOP_HOME}"
ok "Ownership set to ${HADOOP_USER}:${HADOOP_GROUP}"

heading "Shell environment"
profile="/home/${HADOOP_USER}/.bashrc"
java_home="$(detect_java_home)" || die "Could not resolve JAVA_HOME"

# A single marked block, rewritten wholesale, so re-running never appends a
# second copy of the exports.
python3 - "$profile" <<'PY' 2>/dev/null || true
import sys, re, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text() if p.exists() else ""
text = re.sub(r"\n?# >>> hadoop-forge >>>.*?# <<< hadoop-forge <<<\n?", "\n", text, flags=re.S)
p.write_text(text)
PY

cat >> "$profile" <<EOF
# >>> hadoop-forge >>>
export JAVA_HOME=${java_home}
export HADOOP_HOME=${HADOOP_HOME}
export HADOOP_INSTALL=\$HADOOP_HOME
export HADOOP_COMMON_HOME=\$HADOOP_HOME
export HADOOP_HDFS_HOME=\$HADOOP_HOME
export HADOOP_MAPRED_HOME=\$HADOOP_HOME
export HADOOP_YARN_HOME=\$HADOOP_HOME
export HADOOP_CONF_DIR=\$HADOOP_HOME/etc/hadoop
export HADOOP_COMMON_LIB_NATIVE_DIR=\$HADOOP_HOME/lib/native
export PATH=\$PATH:\$HADOOP_HOME/bin:\$HADOOP_HOME/sbin
# <<< hadoop-forge <<<
EOF
chown "${HADOOP_USER}:${HADOOP_GROUP}" "$profile"
ok "Environment exports written to ${profile}"

ok "Step 40 complete. Next: ./scripts/50-apply-config.sh pseudo"
