#!/usr/bin/env python3
"""Make Glide.app self-contained.

Copies every non-system dylib the executable needs (libmpv, FFmpeg, libass,
libplacebo, …, recursively) from Homebrew into Contents/Frameworks and
rewrites all load commands to @executable_path/../Frameworks/…, so the app
runs on Macs without Homebrew.

Usage: bundle_dylibs.py path/to/Glide.app
"""
import os
import shutil
import subprocess
import sys

SYSTEM_PREFIXES = ("/usr/lib/", "/System/")
BUNDLED_PREFIX = "@executable_path/../Frameworks/"
HOMEBREW_LIB = os.path.join(os.environ.get("HOMEBREW_PREFIX", "/opt/homebrew"), "lib")


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def install_id(path):
    lines = run("otool", "-D", path).splitlines()
    return lines[1].strip() if len(lines) > 1 else None


def dependencies(path):
    own_id = install_id(path)
    deps = []
    for line in run("otool", "-L", path).splitlines()[1:]:
        dep = line.strip().split(" (compatibility")[0]
        if dep and dep != own_id:
            deps.append(dep)
    return deps


def rpaths(path):
    result = []
    lines = [line.strip() for line in run("otool", "-l", path).splitlines()]
    for index, line in enumerate(lines):
        if line == "cmd LC_RPATH":
            for candidate in lines[index + 1:index + 4]:
                if candidate.startswith("path "):
                    result.append(candidate[5:].rsplit(" (offset", 1)[0])
    return result


def resolve(dep, original):
    """Turns a load command of `original` (the file's source path) into a real path."""
    loader_dir = os.path.dirname(original)
    if dep.startswith("@loader_path/"):
        candidates = [os.path.join(loader_dir, dep[len("@loader_path/"):])]
    elif dep.startswith("@rpath/"):
        rest = dep[len("@rpath/"):]
        candidates = [os.path.join(rp.replace("@loader_path", loader_dir), rest) for rp in rpaths(original)]
        candidates.append(os.path.join(HOMEBREW_LIB, rest))
    else:
        candidates = [dep]
    for candidate in candidates:
        if os.path.exists(candidate):
            return os.path.realpath(candidate)
    sys.exit(f"error: can't resolve {dep} (needed by {original})")


def main(app):
    executable = os.path.join(app, "Contents", "MacOS", "Glide")
    frameworks = os.path.join(app, "Contents", "Frameworks")
    os.makedirs(frameworks, exist_ok=True)

    copied = {}        # real source path -> bundled file name
    taken_names = set()
    queue = [(executable, executable)]  # (file inside the bundle, its original location)

    while queue:
        target, original = queue.pop()
        changes = []
        for dep in dependencies(target):
            if dep.startswith(SYSTEM_PREFIXES) or dep.startswith("@executable_path/"):
                continue
            real = resolve(dep, original)
            if real.startswith(SYSTEM_PREFIXES):
                continue
            if real not in copied:
                name = os.path.basename(real)
                if name in taken_names:
                    name = f"{os.path.basename(os.path.dirname(real))}-{name}"
                taken_names.add(name)
                destination = os.path.join(frameworks, name)
                shutil.copyfile(real, destination)
                os.chmod(destination, 0o755)
                run("install_name_tool", "-id", BUNDLED_PREFIX + name, destination)
                copied[real] = name
                queue.append((destination, real))
            changes += ["-change", dep, BUNDLED_PREFIX + copied[real]]
        if changes:
            run("install_name_tool", *changes, target)

    # Everything must now point inside the bundle.
    leftovers = []
    for path in [executable] + [os.path.join(frameworks, n) for n in sorted(os.listdir(frameworks))]:
        for dep in dependencies(path):
            if not dep.startswith(SYSTEM_PREFIXES) and not dep.startswith("@executable_path/"):
                leftovers.append(f"{os.path.basename(path)} -> {dep}")
    if leftovers:
        sys.exit("error: unbundled dependencies:\n  " + "\n  ".join(leftovers))

    print(f"Bundled {len(copied)} libraries into {frameworks}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
