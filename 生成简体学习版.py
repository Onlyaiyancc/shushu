from __future__ import annotations

import csv
import hashlib
import re
from html import unescape
from pathlib import Path

from bs4 import BeautifulSoup
from opencc import OpenCC


ROOT = Path(__file__).resolve().parent
SOURCE_ROOTS = [
    ROOT / "资料库" / "在线文本",
]
OUT_ROOT = ROOT / "资料库" / "简体学习版"
INDEX_PATH = OUT_ROOT / "_简体学习版索引.csv"


def sha256_file(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def read_text(path):
    raw = path.read_bytes()
    for encoding in ("utf-8", "utf-8-sig", "gb18030", "big5"):
        try:
            return raw.decode(encoding)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")


def html_to_text(html):
    soup = BeautifulSoup(html, "lxml")

    # 删除网页导航、脚本、样式，保留正文和章节链接文字。
    for tag in soup(["script", "style", "noscript", "svg", "form"]):
        tag.decompose()

    for br in soup.find_all("br"):
        br.replace_with("\n")

    ctp_lines = soup.select("td.ctext")
    if ctp_lines:
        text = "\n".join(tag.get_text("\n") for tag in ctp_lines)
        if len(text.strip()) > 500:
            return unescape(text)

    mediawiki_body = soup.select_one("div.mw-parser-output")
    if mediawiki_body:
        text = mediawiki_body.get_text("\n")
        if len(text.strip()) > 500:
            return unescape(text)

    text = soup.get_text("\n")
    return unescape(text)


def clean_lines(text):
    text = text.replace("\u3000", " ")
    text = text.replace("\xa0", " ")
    text = re.sub(r"[ \t\r\f\v]+", " ", text)
    lines = []
    seen_blank = False
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            if not seen_blank and lines:
                lines.append("")
            seen_blank = True
            continue
        seen_blank = False
        # 保留章节短标题，过滤明显网页控件碎片。
        if line in {
            "编辑",
            "下载",
            "目录",
            "导航",
            "搜索",
            "打印",
            "隐藏",
            "跳至内容",
            "主选单",
            "移至侧边栏",
            "导览",
            "首页",
            "随机作品",
            "随机作者",
            "随机原本",
            "所有页面",
            "编辑者",
            "社群入口",
            "写字间",
            "近期变更",
            "特殊页面",
            "说明",
            "关于维基文库",
            "联络我们",
            "方针与指引",
            "显示选项",
            "搜寻",
            "外观",
            "赞助",
            "建立帐号",
            "登入",
            "个人工具",
            "本站介绍",
            "简介",
            "字体试验页",
            "协助",
            "常见问答集",
            "使用说明",
            "工具",
            "系统统计",
            "数位人文",
            "原典全文",
            "简介说明",
            "相关资料",
            "字典",
            "讨论区",
            "图书馆",
            "维基",
            "数据维基",
            "书名检索",
            "中国哲学书电子化计划",
            "查看正文",
            "修改",
            "查看历史",
        }:
            continue
        if re.fullmatch(r"[+：:]", line):
            continue
        if line.startswith("->"):
            continue
        if re.fullmatch(r"[\[\]（）()|·•\-\s]+", line):
            continue
        lines.append(line)
    return "\n".join(lines).strip() + "\n"


def convert_file(path, converter):
    raw = read_text(path)
    source_kind = path.suffix.lower().lstrip(".")
    if path.suffix.lower() in {".html", ".htm"}:
        text = html_to_text(raw)
    else:
        text = raw

    simplified = converter.convert(clean_lines(text))
    simplified = clean_lines(simplified)

    source_root = next(root for root in SOURCE_ROOTS if path.is_relative_to(root))
    relative = path.relative_to(source_root)
    out_path = OUT_ROOT / source_root.name / relative.with_suffix(relative.suffix + ".simp.txt")
    out_path.parent.mkdir(parents=True, exist_ok=True)

    header = (
        f"# 简体学习版\n"
        f"# 原始文件: {path}\n"
        f"# 来源目录: {source_root}\n"
        f"# 原始SHA256: {sha256_file(path)}\n"
        f"# 说明: 本文件由本地脚本抽取正文并用 OpenCC t2s 转为简体，仅作学习检索；引用和校对仍应回到原始文件。\n\n"
    )
    out_path.write_text(header + simplified, encoding="utf-8")

    return {
        "title": path.stem,
        "source_kind": source_kind,
        "source_path": str(path),
        "output_path": str(out_path),
        "source_sha256": sha256_file(path),
        "output_chars": len(simplified),
    }


def main():
    OUT_ROOT.mkdir(parents=True, exist_ok=True)
    converter = OpenCC("t2s")
    rows = []

    for source_root in SOURCE_ROOTS:
        if not source_root.exists():
            continue
        for path in sorted(source_root.rglob("*")):
            if path.is_file() and path.suffix.lower() in {".html", ".htm", ".txt"}:
                rows.append(convert_file(path, converter))

    with INDEX_PATH.open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "title",
                "source_kind",
                "source_path",
                "output_path",
                "source_sha256",
                "output_chars",
            ],
        )
        writer.writeheader()
        writer.writerows(rows)

    readme = OUT_ROOT / "README.md"
    readme.write_text(
        "# 简体学习版资料库\n\n"
        "这里的文件由 `生成简体学习版.py` 从本地 HTML/TXT 抽取并转换而来，适合阅读、检索和蒸馏规则。\n\n"
        "注意：这些不是新的权威底本。遇到关键规则、疑难句、版本差异时，必须回到索引中的原始文件或影印本校对。\n\n"
        f"- 索引：`{INDEX_PATH}`\n"
        f"- 已生成文件数：{len(rows)}\n",
        encoding="utf-8",
    )

    print(f"Generated {len(rows)} simplified study files.")
    print(f"Index: {INDEX_PATH}")


if __name__ == "__main__":
    main()
