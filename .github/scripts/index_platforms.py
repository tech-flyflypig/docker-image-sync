#!/usr/bin/env python3
"""解析 OCI index / Docker manifest list，输出可搬运的平台清单。

用法：python3 index_platforms.py <index.json>

输出（`|` 分隔，空字段也保留）：
    ATT|<attestation 数量>          # buildx 产物里 os=unknown 的清单，ACR 不接受
    PF|<os>|<arch>|<variant>|<digest>
"""
import json
import sys


def main() -> int:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)

    manifests = data.get("manifests") or []
    attestations = 0
    for m in manifests:
        platform = m.get("platform") or {}
        if platform.get("os") == "unknown":
            attestations += 1

    print("ATT", attestations, sep="|")
    for m in manifests:
        platform = m.get("platform") or {}
        os_name = platform.get("os")
        if os_name in (None, "unknown"):
            continue
        print(
            "|".join(
                [
                    "PF",
                    str(os_name),
                    platform.get("architecture", "") or "",
                    platform.get("variant", "") or "",
                    m.get("digest", "") or "",
                ]
            )
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
