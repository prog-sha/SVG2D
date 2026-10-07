#!/usr/bin/env python
# 共有生成物の内容を一括で読み、作業場所に依存しない指紋を作る。
# ファイルごとの外部コマンド起動を避け、既存の相対パス順と指紋形式を保つ。
import hashlib
import sys
from pathlib import Path


def generated_digest(root: Path) -> str:
    """生成されたC++ファイルだけを、相対パスのバイト順で集計する。"""
    suffixes = {".h", ".hpp", ".inc", ".cpp"}  # 共有バインディングの入力形式
    paths = sorted(
        (p for p in (root / "godot-cpp/gen").rglob("*")
         if p.suffix in suffixes and p.is_file() and not p.is_symlink()),
        key=lambda p: p.relative_to(root).as_posix().encode(),
    )
    total = hashlib.sha256()
    for path in paths:
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        total.update(f"{path.relative_to(root).as_posix()} {digest.hexdigest()}\n".encode())
    return total.hexdigest()


if __name__ == "__main__":
    print(generated_digest(Path(sys.argv[1]).resolve()))
