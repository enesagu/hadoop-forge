#!/usr/bin/env bash
#
# 30 — Passwordless SSH for the hadoop user.
#
#   sudo -iu hadoop /path/to/scripts/30-setup-ssh.sh [worker1 worker2 ...]
#
# start-dfs.sh and start-yarn.sh do not use any cluster protocol to launch
# daemons — they literally SSH to each host in the `workers` file and run a
# command. No passwordless SSH, no cluster.

source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

refuse_root

WORKERS=("$@")
KEY_FILE="${HOME}/.ssh/id_ed25519"

heading "Key pair"
mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"

if [[ -f "${KEY_FILE}" ]]; then
  skip "Key already present at ${KEY_FILE}"
else
  # ed25519 over RSA: shorter, faster, and supported by every OpenSSH release
  # Hadoop 3.x would realistically run against.
  ssh-keygen -t ed25519 -N '' -C "hadoop-forge@$(hostname)" -f "${KEY_FILE}"
  ok "Generated ${KEY_FILE}"
fi

heading "Authorising the key on localhost"
if ensure_line_in_file "$(cat "${KEY_FILE}.pub")" "${HOME}/.ssh/authorized_keys"; then
  ok "Added public key to authorized_keys"
else
  skip "Public key already in authorized_keys"
fi
# sshd silently ignores authorized_keys if it is group-writable.
chmod 600 "${HOME}/.ssh/authorized_keys"

heading "Client configuration"
cat > "${HOME}/.ssh/config" <<'EOF'
# Written by scripts/30-setup-ssh.sh
Host *
  # Keep host key verification on, but accept and record keys on first contact
  # so start-dfs.sh is not blocked by an interactive prompt it cannot answer.
  StrictHostKeyChecking accept-new
  # Reuse one TCP connection per host: launching daemons across 50 workers
  # otherwise pays a full handshake per SSH invocation.
  ControlMaster auto
  ControlPath ~/.ssh/cm-%r@%h:%p
  ControlPersist 60s
  ServerAliveInterval 30
EOF
chmod 600 "${HOME}/.ssh/config"
ok "Wrote ~/.ssh/config"

heading "Verifying localhost"
# 'localhost' and '0.0.0.0' both appear in Hadoop's start scripts.
for host in localhost 0.0.0.0 "$(hostname)"; do
  if ssh -o BatchMode=yes -o ConnectTimeout=5 "$host" true 2>/dev/null; then
    ok "ssh ${host} works without a password"
  else
    warn "ssh ${host} failed — pseudo-distributed startup will hang on this host"
  fi
done

if (( ${#WORKERS[@]} > 0 )); then
  heading "Distributing the key to workers"
  for w in "${WORKERS[@]}"; do
    log "ssh-copy-id ${HADOOP_USER}@${w}"
    if ssh-copy-id -i "${KEY_FILE}.pub" -o StrictHostKeyChecking=accept-new "${HADOOP_USER}@${w}"; then
      ssh -o BatchMode=yes -o ConnectTimeout=5 "${HADOOP_USER}@${w}" true \
        && ok "${w} reachable without a password" \
        || warn "${w} still prompting — check sshd PasswordAuthentication and file modes"
    else
      warn "Could not copy the key to ${w}"
    fi
  done
fi

ok "Step 30 complete"
