#!/usr/bin/env python3
"""Bundle the pinned, pure Life Core policies for JavaScriptCore."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
REVISION = "df15dd2c93a45f3517628ac500d9a9d768e60b69"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", required=True, type=Path, help="Clean Life Data source checkout")
args = parser.parse_args()
source = args.source.resolve()
head = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
dirty = subprocess.check_output(["git", "-C", str(source), "status", "--porcelain"], text=True)
if head != REVISION or dirty:
    parser.error("Life Data source must be clean at the pinned revision")
with tempfile.TemporaryDirectory(prefix="circle-core-") as scratch:
    entry = Path(scratch) / "entry.ts"
    entry.write_text(
        "import * as enrollment from " + json.dumps(str(source / "core/src/enrollment.ts")) + ";\n"
        "import { canonicalConsumerConfig } from " + json.dumps(str(source / "core/src/consumer-config.ts")) + ";\n"
        "globalThis.CircleCore = {...enrollment, canonicalConsumerConfig};\n"
    )
    output = Path(scratch) / "core.js"
    subprocess.run(["bun", "build", str(entry), "--target", "browser", "--format", "iife", "--minify", "--outfile", str(output)], check=True)
    target = ROOT / "nudge/nudge/Graph/Resources/life-core.js"
    target.write_text("// Generated from Life Core " + REVISION + ". Rebuild with scripts/bundle_life_core.py.\n" + output.read_text())
