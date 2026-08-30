from __future__ import annotations

import time
import urllib.parse
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parent
OUT_DIR = ROOT / "资料库" / "在线文本" / "维基文库" / "三命通会四库本-卷页"
BASE = "https://zh.wikisource.org/zh-hans/三命通會_(四庫全書本)/卷{num:02d}"


def fetch(url, out_path):
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "CodexFortuneStudy/1.0 (local study corpus builder)",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as response:
        data = response.read()
    out_path.write_bytes(data)
    return len(data)


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    rows = []
    for i in range(1, 13):
        url = urllib.parse.quote(BASE.format(num=i), safe=":/()")
        safe_name = f"三命通会四库本 卷{i:02d} - 维基文库 zh-hans.html"
        out_path = OUT_DIR / safe_name
        size = fetch(url, out_path)
        rows.append((i, size, url, out_path))
        print(f"Downloaded volume {i:02d}: {size} bytes")
        time.sleep(0.8)

    index = OUT_DIR / "_下载索引.tsv"
    index.write_text(
        "volume\tsize\turl\tpath\n"
        + "\n".join(f"{i}\t{size}\t{url}\t{path}" for i, size, url, path in rows)
        + "\n",
        encoding="utf-8",
    )
    print(f"Index: {index}")


if __name__ == "__main__":
    main()
