"""Exercise current and v0.5.4 shell installers against local release payloads."""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile


def run():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    binary = parser.parse_args().binary.resolve()
    repo = Path(__file__).resolve().parent.parent
    version = subprocess.check_output([binary, "--version"], text=True).split()[1]
    target = {
        ("Darwin", "arm64"): "aarch64-apple-darwin",
        ("Darwin", "x86_64"): "x86_64-apple-darwin",
        ("Linux", "x86_64"): "x86_64-unknown-linux-gnu",
        ("Linux", "aarch64"): "aarch64-unknown-linux-gnu",
    }[(platform.system(), platform.machine())]
    with tempfile.TemporaryDirectory(prefix="fortify-installer-test-") as temporary:
        root = Path(temporary)
        fixtures = root / "releases"
        fixtures.mkdir()
        sums = []
        for product in ("fortify", "embrasure"):
            name = f"{product}-{version}-{target}"
            payload = root / name
            (payload / "python").mkdir(parents=True)
            # Installer validates discovery; Rust tests validate SQLGlot loading separately.
            (payload / "python/sqlglot-30.7.0-py3-none-any.whl").write_bytes(b"fixture")
            for command in ("fortify", "embrasure"):
                shutil.copy2(binary, payload / command)
            archive = fixtures / f"{name}.tar.gz"
            with tarfile.open(archive, "w:gz") as tar:
                tar.add(payload, arcname=name)
            sums.append(f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}")
        (fixtures / "SHA256SUMS").write_text("\n".join(sums) + "\n")
        mock_bin = root / "mock-bin"
        mock_bin.mkdir()
        curl = mock_bin / "curl"
        curl.write_text("""#!/usr/bin/env python3
import os, pathlib, shutil, sys
args = sys.argv[1:]
url = next(a for a in args if a.startswith('https://'))
source = pathlib.Path(os.environ['FIXTURE_RELEASES']) / url.rsplit('/', 1)[1]
shutil.copyfile(source, args[args.index('-o') + 1])
""")
        curl.chmod(0o755)
        env = os.environ | {
            "PATH": f"{mock_bin}:{os.environ['PATH']}",
            "FIXTURE_RELEASES": str(fixtures),
            "EMBRASURE_VERSION": version,
        }
        for key in ("FORTIFY_VERSION", "FORTIFY_INSTALL_DIR"):
            env.pop(key, None)
        destination = root / "existing install/bin"
        env["EMBRASURE_INSTALL_DIR"] = str(destination)
        subprocess.run(["sh", repo / "tests/fixtures/v0.5.4/install.sh"], env=env, check=True)
        assert subprocess.check_output([destination / "embrasure", "--version"], text=True) == f"embrasure {version}\n"
        subprocess.run(["sh", repo / "install.sh"], env=env, check=True)
        for command in ("fortify", "embrasure"):
            assert subprocess.check_output([destination / command, "--version"], text=True) == f"{command} {version}\n"
        # Canonical environment variables override legacy values, including version.
        canonical = root / "fresh install/bin"
        env |= {"FORTIFY_INSTALL_DIR": str(canonical), "FORTIFY_VERSION": version, "EMBRASURE_VERSION": "0.0.0"}
        subprocess.run(["sh", repo / "install.sh"], env=env, check=True)
        assert (canonical / "fortify").exists()
        assert (canonical / ".fortify/python/sqlglot-30.7.0-py3-none-any.whl").exists()
        original = (canonical / "fortify").read_bytes()
        (fixtures / "SHA256SUMS").write_text("0" * 64 + f"  fortify-{version}-{target}.tar.gz\n")
        assert subprocess.run(["sh", repo / "install.sh"], env=env).returncode != 0
        assert (canonical / "fortify").read_bytes() == original
    print("Canonical and legacy installers, aliases, precedence, and checksum rejection passed.")


if __name__ == "__main__":
    run()
