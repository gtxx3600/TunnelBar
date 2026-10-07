#!/usr/bin/env python3
"""Optional real SSH smoke test. Temporary keys/config; loopback connections only."""
import getpass
import json
import os
import pathlib
import signal
import socket
import subprocess
import tempfile
import time

PROJECT = pathlib.Path(__file__).resolve().parent.parent


def free_ports(count):
    sockets = []
    try:
        for _ in range(count):
            listener = socket.socket()
            listener.bind(("127.0.0.1", 0))
            sockets.append(listener)
        return [listener.getsockname()[1] for listener in sockets]
    finally:
        for listener in sockets:
            listener.close()


def main():
    with tempfile.TemporaryDirectory(prefix="tunnelbar-local-ssh-") as directory:
        root = pathlib.Path(directory)
        for name in ("host", "identity"):
            subprocess.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / name)], check=True)
        ssh_port, local_port, socks_port, remote_port = free_ports(4)
        config = root / "sshd_config"
        config.write_text("\n".join([
            f"Port {ssh_port}", "ListenAddress 127.0.0.1",
            f"HostKey {root / 'host'}", f"PidFile {root / 'server.pid'}",
            f"AuthorizedKeysFile {root / 'identity.pub'}",
            "StrictModes no", "UsePAM no", "PasswordAuthentication no",
            "KbdInteractiveAuthentication no", "PubkeyAuthentication yes",
            "AllowTcpForwarding yes", "LogLevel ERROR",
        ]) + "\n")
        host_key = " ".join((root / "host.pub").read_text().split()[:2])
        known_hosts = root / "known_hosts"
        known_hosts.write_text(f"[127.0.0.1]:{ssh_port} {host_key}\n")
        executable = root / "local-ssh-test"
        sources = ["TunnelModels", "PrivateStorage", "ConfigStore", "TunnelManager", "TunnelDiagnostics", "TunnelPreflight"]
        subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library",
                        *[str(PROJECT / "Sources" / (name + ".swift")) for name in sources],
                        str(PROJECT / "Tests/LocalSSHIntegration.swift"), "-o", str(executable)], check=True)
        app_config = root / "app/config.json"
        app_config.parent.mkdir(mode=0o700)
        rules = [
            dict(type="L", bind="127.0.0.1", port=str(local_port), host="127.0.0.1", rport=str(ssh_port)),
            dict(type="D", bind="127.0.0.1", port=str(socks_port)),
            dict(type="R", bind="127.0.0.1", port=str(remote_port), host="127.0.0.1", rport=str(ssh_port)),
        ]
        app_config.write_text(json.dumps(dict(
            nodes=[dict(id="local", name="Temporary loopback SSH", host="127.0.0.1", port=str(ssh_port),
                        user=getpass.getuser(), identityFile=str(root / "identity"))],
            tunnels=[dict(id="local-integration", name="Local integration", nodeId="local", forwards=rules,
                          extraArgs=["-F", "/dev/null", "-o", "StrictHostKeyChecking=yes", "-o", "BatchMode=yes",
                                     "-o", "IdentityAgent=none", "-o", f"UserKnownHostsFile={known_hosts}"])],
        )))
        server_log = root / "server.log"
        server = subprocess.Popen(["/usr/sbin/sshd", "-D", "-f", str(config), "-E", str(server_log)])
        try:
            time.sleep(0.25)
            if server.poll() is not None:
                raise RuntimeError(server_log.read_text() if server_log.exists() else "Local sshd exited")
            subprocess.run([str(executable), str(app_config)], check=True, timeout=45)
        finally:
            pid_file = app_config.parent / "run/local-integration.pid"
            if pid_file.exists():
                pid = int(pid_file.read_text())
                command = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True).stdout
                if command.startswith("/usr/bin/ssh ") and str(root / "identity") in command:
                    try:
                        os.kill(pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
            server.terminate()
            try:
                server.wait(timeout=3)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()


if __name__ == "__main__":
    main()
