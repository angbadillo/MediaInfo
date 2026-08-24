#!/usr/bin/env python3
"""Copies the FFmpeg helper binaries and their Homebrew dylib tree into the app bundle.

Homebrew binaries reference their libraries by absolute path under /opt/homebrew,
so a plain copy would break on any machine without that exact Homebrew install.
Every install name is rewritten to a bundle-relative one:

    Contents/Helpers/ffprobe        -> @executable_path/../Frameworks/<lib>
    Contents/Frameworks/<lib>       -> @loader_path/<lib>

Modifying a Mach-O invalidates its signature, so each file is re-signed ad hoc
afterwards; on Apple silicon an unsigned binary simply will not run.
"""

import os
import shutil
import subprocess
import sys

PREFIXES = ("/opt/homebrew", "/usr/local/Cellar", "/usr/local/opt")


def dependencies(path):
    output = subprocess.run(["otool", "-L", path], capture_output=True, text=True).stdout
    result = []
    for line in output.splitlines()[1:]:
        name = line.strip().split(" ")[0]
        if name.startswith(PREFIXES):
            result.append(name)
    return result


def collect(binary):
    """Every Homebrew dylib reachable from `binary`, transitively."""
    seen = {}
    pending = [binary]
    while pending:
        current = os.path.realpath(pending.pop())
        if current in seen or not os.path.exists(current):
            continue
        seen[current] = os.path.basename(current)
        pending.extend(dependencies(current))
    seen.pop(os.path.realpath(binary), None)
    return seen


def run(command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"error: {' '.join(command)}\n{result.stderr}")


def sign(path):
    run(["codesign", "--force", "--sign", "-", "--timestamp=none", path])


def main():
    if len(sys.argv) < 3:
        raise SystemExit("uso: bundle_helpers.py <ruta-app> <binario> [binario…]")

    app, sources = sys.argv[1], sys.argv[2:]
    for source in sources:
        if not os.path.isfile(source):
            raise SystemExit(f"error: no se encontró {source}")

    helpers = os.path.join(app, "Contents", "Helpers")
    frameworks = os.path.join(app, "Contents", "Frameworks")
    os.makedirs(helpers, exist_ok=True)
    os.makedirs(frameworks, exist_ok=True)

    # ffmpeg and ffprobe share the same libraries, so the trees are merged.
    libraries = {}
    for source in sources:
        libraries.update(collect(source))

    # Map every possible spelling of a dependency (symlink or realpath) to its basename,
    # because otool reports whichever path was recorded at link time.
    resolved = {}
    for real, name in libraries.items():
        resolved[real] = name
    for real, name in list(libraries.items()):
        directory = os.path.dirname(real)
        for entry in os.listdir(directory):
            candidate = os.path.join(directory, entry)
            if os.path.islink(candidate) and os.path.realpath(candidate) == real:
                resolved[candidate] = name

    def rewrite(path, dependency_prefix):
        for dependency in dependencies(path):
            name = resolved.get(dependency) or resolved.get(os.path.realpath(dependency))
            if not name:
                # A Homebrew path we did not collect: the tree walk missed it.
                raise SystemExit(f"error: dependencia sin empaquetar: {dependency} (en {path})")
            run(["install_name_tool", "-change", dependency, f"{dependency_prefix}{name}", path])

    for real, name in libraries.items():
        target = os.path.join(frameworks, name)
        shutil.copy2(real, target)
        os.chmod(target, 0o755)  # Homebrew ships them read-only.
        run(["install_name_tool", "-id", f"@loader_path/{name}", target])

    for name in libraries.values():
        rewrite(os.path.join(frameworks, name), "@loader_path/")

    binaries = []
    for source in sources:
        binary = os.path.join(helpers, os.path.basename(source))
        shutil.copy2(source, binary)
        os.chmod(binary, 0o755)
        rewrite(binary, "@executable_path/../Frameworks/")
        binaries.append(binary)

    for name in libraries.values():
        sign(os.path.join(frameworks, name))
    for binary in binaries:
        sign(binary)

    total = sum(os.path.getsize(os.path.join(frameworks, n)) for n in libraries.values())
    total += sum(os.path.getsize(b) for b in binaries)
    names = " + ".join(os.path.basename(b) for b in binaries)
    print(f"  {names} + {len(libraries)} bibliotecas ({total / 1e6:.1f} MB)")

    # Prove the rewritten binaries actually run from inside the bundle.
    for binary in binaries:
        check = subprocess.run([binary, "-version"], capture_output=True, text=True)
        if check.returncode != 0:
            raise SystemExit(f"error: el {os.path.basename(binary)} empaquetado no arranca\n{check.stderr}")
        print(f"  verificado: {check.stdout.splitlines()[0]}")


if __name__ == "__main__":
    main()
