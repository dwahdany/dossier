#!/usr/bin/python3
"""Builds the synthetic demo data set that Dossier shows when DOSSIER_DEMO_ROOT is set.

    scripts/make-demo-data.py <out-dir> [--seed N] [--only graph,biome] [--now ISO-8601]
    scripts/make-demo-data.py --check          # unit checks of the shared helpers

Creates <out-dir>/Home/... and <out-dir>/private/var/... by calling one generator per
module (scripts/demo/<moduleID>.py, `generate(root, persona, rng, now)`). Python standard
library only. Everything written is invented; nothing is read from this Mac's stores.

Then:
    DOSSIER_DEMO_ROOT=<out-dir> .build/debug/Dossier --selftest
    DOSSIER_DEMO_ROOT=<out-dir> .build/debug/Dossier --snapshot overview /tmp/overview.png
"""

from __future__ import annotations

import argparse
import datetime
import importlib
import pathlib
import random
import shutil
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from demo import MODULE_IDS, lib, persona as persona_module  # noqa: E402

MARKER = ".dossier-demo-root"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("out_dir", nargs="?", help="directory to create (must be empty, absent, or an earlier demo root)")
    parser.add_argument("--seed", type=int, default=persona_module.SEED_DEFAULT, help="random seed (default %(default)s)")
    parser.add_argument("--only", default="", help="comma-separated module ids (default: all)")
    parser.add_argument("--now", default="", help="pretend this is the current time (ISO 8601, UTC) — for reproducible output")
    parser.add_argument("--check", action="store_true", help="run the helper unit checks and exit")
    args = parser.parse_args()

    if args.check:
        from demo import selfcheck
        return selfcheck.run()
    if not args.out_dir:
        parser.error("out_dir is required")

    root = pathlib.Path(args.out_dir).expanduser().resolve()
    # Safety: never write into a real home or system location, and only ever delete a
    # directory this script created itself.
    real_home = pathlib.Path.home().resolve()
    def below(path: pathlib.Path, parent: pathlib.Path) -> bool:
        return path == parent or parent in path.parents
    stores = [real_home / "Library", real_home / "Pictures", pathlib.Path("/private/var/db"),
              pathlib.Path("/System"), pathlib.Path("/Library")]
    if root == real_home or root == pathlib.Path("/") or any(below(root, store.resolve()) for store in stores):
        parser.error(f"refusing to use {root} as a demo root: it is, or lies inside, a location that holds real stores")
    if root.exists():
        if any(root.iterdir()) and not (root / MARKER).exists():
            parser.error(f"{root} exists, is not empty and was not created by this script")
        shutil.rmtree(root)
    root.mkdir(parents=True)
    (root / MARKER).write_text("Synthetic demo data for Dossier. Every value is invented. Safe to delete.\n", encoding="utf-8")
    lib.ensure_dir(lib.library(root))
    lib.ensure_dir(root / "private" / "var")

    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    if args.now:
        now = datetime.datetime.fromisoformat(args.now.replace("Z", "+00:00"))
        if now.tzinfo is None:
            now = now.replace(tzinfo=datetime.timezone.utc)

    lib.SEED = args.seed
    persona = persona_module.build(args.seed)
    problems = persona_module.audit(persona)
    if problems:
        print("persona problems:\n  " + "\n  ".join(problems), file=sys.stderr)
        return 1

    wanted = [m for m in args.only.split(",") if m] or MODULE_IDS
    unknown = [m for m in wanted if m not in MODULE_IDS]
    if unknown:
        parser.error("unknown module id(s): " + ", ".join(unknown))

    print(f"demo root  {root}")
    print(f"persona    {persona.owner.full_name}, {persona.place('home').city} · seed {args.seed} · now {lib.iso(now)}")
    failed = 0
    for module_id in wanted:
        module = importlib.import_module(f"demo.{module_id}")
        # One independent random stream per module: a module's output does not change when
        # another module draws more or fewer numbers.
        rng = random.Random(f"dossier-demo-{args.seed}-{module_id}")
        before = _inventory(root)
        started = time.time()
        try:
            module.generate(root, persona, rng, now)
        except Exception as error:  # keep going: one broken generator must not hide the others
            failed += 1
            import traceback
            traceback.print_exc()
            print(f"  {module_id:<12} FAILED: {error}")
            continue
        after = _inventory(root)
        new = {p: s for p, s in after.items() if p not in before or before[p] != s}
        size = sum(new.values())
        print(f"  {module_id:<12} {len(new):>4} files  {size / 1024:>9.1f} kB  {time.time() - started:5.2f}s")
    total = _inventory(root)
    print(f"total      {len(total)} files, {sum(total.values()) / 1024:.1f} kB")
    print(f"\nrun        DOSSIER_DEMO_ROOT='{root}' <Dossier binary> --selftest")
    return 1 if failed else 0


def _inventory(root: pathlib.Path) -> dict[str, int]:
    return {str(p.relative_to(root)): p.stat().st_size for p in root.rglob("*") if p.is_file()}


if __name__ == "__main__":
    sys.exit(main())
