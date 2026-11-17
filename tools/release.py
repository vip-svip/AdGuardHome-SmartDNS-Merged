#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
一键发版：打包 module/ → 建 tag → 建/更新 Release → 上传 zip。

用法:
    python tools/release.py                 # 用 module.prop 里的 version 作为 tag
    python tools/release.py --tag v1.2.3    # 指定 tag
    python tools/release.py --dry-run       # 只看会做什么，不发请求
    python tools/release.py --no-upload     # 只建 tag + Release，不传 zip
    python tools/release.py --notes "..."   # 附加到 Release 说明

Token（按顺序找）:
    1. 环境变量 GITHUB_TOKEN
    2. 文件 .gh_token（仓库根或上一级）
    3. 环境变量 GH_TOKEN

依赖: git（需在仓库里）、zip、curl 或 urllib（脚本用标准库 urllib，不依赖 curl）
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
import zipfile

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULE_DIR = os.path.join(ROOT, "module")
PROP = os.path.join(MODULE_DIR, "module.prop")

# 不进 zip 的运行期垃圾
EXCLUDE_PREFIXES = (
    "bin/data/",
    "rules/subscriptions/",
    "smartdns/tmp/",
    "smartdns/var/",
    "smartdns/run/",
    "smartdns/proc/",
    "smartdns/sys/",
    "smartdns/dev/",
)
EXCLUDE_SUFFIXES = (".log", ".DS_Store", "Thumbs.db")


# ---------------------------------------------------------------- 基础
def die(msg):
    print("错误: " + msg)
    sys.exit(1)


def read_prop():
    if not os.path.exists(PROP):
        die("找不到 " + PROP)
    d = {}
    for line in open(PROP, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        d[k.strip()] = v.strip()
    return d


def find_token():
    tok = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if tok:
        return tok.strip()
    for p in (os.path.join(ROOT, ".gh_token"),
              os.path.join(os.path.dirname(ROOT), ".gh_token")):
        if os.path.exists(p):
            return open(p, encoding="utf-8").read().strip()
    die("找不到 token：设 GITHUB_TOKEN 环境变量，或把 token 写进 .gh_token")


def run(args, cwd=ROOT):
    p = subprocess.run(args, cwd=cwd, capture_output=True)
    return ((p.stdout or b"") + (p.stderr or b"")).decode("utf-8", "replace"), p.returncode


def detect_repo():
    """从 git remote 解析 owner/repo。"""
    out, rc = run(["git", "remote", "get-url", "origin"])
    if rc != 0:
        die("没有 git remote origin")
    m = re.search(r"github\.com[:/]+([^/]+)/([^/]+?)(?:\.git)?$", out.strip())
    if not m:
        die("解析不了 remote: " + out.strip())
    return m.group(1), m.group(2)


# ---------------------------------------------------------------- GitHub API
class GH:
    def __init__(self, token):
        self.token = token

    def call(self, method, path, body=None, upload=None, host="https://api.github.com"):
        url = path if path.startswith("http") else host + path
        data = None
        headers = {
            "Authorization": "Bearer " + self.token,
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "agh-release-script",
        }
        if upload is not None:
            data = upload
            headers["Content-Type"] = "application/zip"
        elif body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=900) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            raw = e.read().decode("utf-8", "replace")
            try:
                return json.loads(raw)
            except Exception:
                return {"_error": e.code, "_raw": raw}
        except Exception as e:
            return {"_error": str(e)}


# ---------------------------------------------------------------- 打包
def build_zip(out_path):
    files = 0
    skipped = 0
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for root, dirs, names in os.walk(MODULE_DIR):
            dirs.sort()
            rel_dir = os.path.relpath(root, MODULE_DIR).replace("\\", "/")
            if rel_dir == ".":
                rel_dir = ""
            for n in sorted(names):
                rel = (rel_dir + "/" + n) if rel_dir else n
                if any(rel.startswith(p) for p in EXCLUDE_PREFIXES) or rel.endswith(EXCLUDE_SUFFIXES):
                    skipped += 1
                    continue
                full = os.path.join(root, n)
                zi = zipfile.ZipInfo.from_file(full, rel)
                zi.external_attr = (0o644 & 0xFFFF) << 16
                with open(full, "rb") as fh:
                    z.writestr(zi, fh.read(), compress_type=zipfile.ZIP_DEFLATED)
                files += 1
    return files, skipped


def md5_of(p):
    h = hashlib.md5()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_of(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------- 主流程
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", default="")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-upload", action="store_true")
    ap.add_argument("--notes", default="")
    ap.add_argument("--name", default="")
    a = ap.parse_args()

    prop = read_prop()
    version = prop.get("version", "")
    if not version:
        die("module.prop 里没有 version=")
    tag = a.tag or ("v" + version)
    author = prop.get("author", "")
    zip_name = "AdGuardHome-SmartDNS-Merged-%s.zip" % version
    zip_path = os.path.join(ROOT, zip_name)

    print("仓库   :", ROOT)
    print("版本   :", version, "| versionCode:", prop.get("versionCode", ""))
    print("作者   :", author)
    print("tag    :", tag)
    print("产物   :", zip_name)

    if a.dry_run:
        print("\n[dry-run] 会打包 module/ → 建 tag %s → 建/更新 Release → 上传 %s" % (tag, zip_name))
        return

    owner, repo = detect_repo()
    token = find_token()
    gh = GH(token)
    print("远端   : %s/%s" % (owner, repo))

    # 1) 打包
    print("\n[1/5] 打包…")
    files, skipped = build_zip(zip_path)
    size = os.path.getsize(zip_path)
    md5 = md5_of(zip_path)
    sha = sha256_of(zip_path)
    print("      %d 个文件（跳过 %d）  %d B  md5=%s" % (files, skipped, size, md5))

    # 2) 校验 tag 与工作区状态
    print("\n[2/5] 检查 git 状态…")
    out, _ = run(["git", "status", "--porcelain"])
    if out.strip():
        print("      注意：工作区有未提交改动 ——")
        for l in out.strip().split("\n")[:10]:
            print("        " + l)
    head, rc = run(["git", "rev-parse", "HEAD"])
    if rc != 0:
        die("读不到 HEAD")
    head = head.strip()
    print("      HEAD =", head[:12])

    # 3) 建 tag（已存在就跳过）
    print("\n[3/5] 建 tag %s …" % tag)
    ex = gh.call("GET", "/repos/%s/%s/git/ref/tags/%s" % (owner, repo, tag))
    if "ref" in ex:
        print("      tag 已存在 ->", ex["object"]["sha"][:12])
    else:
        r = gh.call("POST", "/repos/%s/%s/git/refs" % (owner, repo),
                    {"ref": "refs/tags/" + tag, "sha": head})
        if "ref" in r:
            print("      已建 ->", r["object"]["sha"][:12])
        else:
            print("      建 tag 失败:", json.dumps(r, ensure_ascii=False)[:300])

    # 4) 建/更新 Release
    print("\n[4/5] 建/更新 Release …")
    body_lines = []
    if a.notes:
        body_lines += [a.notes, ""]
    body_lines += [
        "作者：%s" % author,
        "",
        "AdGuard Home + SmartDNS 合并 Magisk / KernelSU 模块（arm64）。",
        "",
        "### 安装",
        "",
        "1. 下载 `%s`" % zip_name,
        "2. 在 KernelSU / Magisk 里刷入，或解开到 `/data/adb/modules/AdGuardHome`",
        "3. 重启设备",
        "4. 端口：AdGuard Home 面板 `40251` · SmartDNS 面板 `6080` · 上游管理 `6081`（仅 `127.0.0.1`）",
        "",
        "### 校验",
        "",
        "```",
        "大小    %d B" % size,
        "md5     %s" % md5,
        "sha256  %s" % sha,
        "```",
    ]
    payload = {
        "tag_name": tag,
        "target_commitish": "main",
        "name": a.name or ("%s · AdGuard Home + SmartDNS 合并模块" % version),
        "body": "\n".join(body_lines),
        "draft": False,
        "prerelease": False,
    }
    rel = gh.call("GET", "/repos/%s/%s/releases/tags/%s" % (owner, repo, tag))
    if "id" in rel:
        rid = rel["id"]
        print("      Release 已存在 id=%s，更新说明" % rid)
        upd = gh.call("PATCH", "/repos/%s/%s/releases/%s" % (owner, repo, rid),
                      {"name": payload["name"], "body": payload["body"]})
        print("      说明更新:", "ok" if "id" in upd else json.dumps(upd, ensure_ascii=False)[:200])
        assets = rel.get("assets") or []
    else:
        rel = gh.call("POST", "/repos/%s/%s/releases" % (owner, repo), payload)
        if "id" not in rel:
            die("建 Release 失败: " + json.dumps(rel, ensure_ascii=False)[:500])
        rid = rel["id"]
        print("      已建 Release id=%s" % rid)
        assets = []
    print("      页面:", "https://github.com/%s/%s/releases/tag/%s" % (owner, repo, tag))

    if a.no_upload:
        print("\n[5/5] 跳过上传（--no-upload）")
        return

    # 5) 上传 asset（同名先删）
    print("\n[5/5] 上传 %s …" % zip_name)
    for aset in assets:
        if aset["name"] == zip_name:
            d = gh.call("DELETE", "/repos/%s/%s/releases/assets/%s" % (owner, repo, aset["id"]))
            print("      删除旧同名 asset id=%s -> %s" % (aset["id"], "ok" if not d.get("_error") else d))

    upload_host = "https://uploads.github.com"
    with open(zip_path, "rb") as f:
        data = f.read()
    up = gh.call("POST",
                 "/repos/%s/%s/releases/%s/assets?name=%s" % (owner, repo, rid, zip_name),
                 upload=data, host=upload_host)
    if "id" in up:
        print("      已上传 id=%s  %s B  state=%s" % (up["id"], up.get("size"), up.get("state")))
        print("      下载:", up.get("browser_download_url"))
    else:
        die("上传失败: " + json.dumps(up, ensure_ascii=False)[:500])

    print("\n完成。Releases 已更新到 %s" % tag)


if __name__ == "__main__":
    main()
