#!/usr/bin/env python3
"""把 RustDesk 源码改造成 homeuu。

在编译前对 RustDesk 源码树执行一次（CI 里自动执行）：

    python3 customize.py <rustdesk 源码目录> [--config homeuu.json]

服务器信息从环境变量读取（对应 GitHub Secrets），不写进仓库：

    HOMEUU_SERVER  ID 服务器，host:port，例如 1.2.3.4:31116
    HOMEUU_RELAY   中继服务器，host:port，例如 1.2.3.4:31117
    HOMEUU_KEY     服务器公钥（id_ed25519.pub 的内容）

三个变量都没设置时只做改名，服务器需要在客户端设置里手动填写；只设置一部分会报错。

每处替换都会检查原文是否存在，RustDesk 升级后原文变了会直接报错，
不会悄悄漏改。
"""

import argparse
import base64
import json
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


class Patcher:
    def __init__(self, root: Path):
        self.root = root
        self.changed = set()

    def sub(self, rel, old, new, count=1):
        """把 old 替换成 new。count 为期望出现次数，None 表示至少一次。"""
        path = self.root / rel
        text = path.read_text(encoding="utf-8")
        n = text.count(old)
        if n == 0 or (count is not None and n != count):
            want = "至少 1" if count is None else str(count)
            sys.exit(f"[customize] {rel}: 期望找到 {want} 处 {old!r}，实际 {n} 处。RustDesk 源码可能已变化。")
        path.write_text(text.replace(old, new), encoding="utf-8")
        self.changed.add(rel)

    def re_sub(self, rel, pattern, new, count=1):
        path = self.root / rel
        text = path.read_text(encoding="utf-8")
        result, n = re.subn(pattern, new, text)
        if n != count:
            sys.exit(f"[customize] {rel}: 期望匹配 {count} 处 /{pattern}/，实际 {n} 处。RustDesk 源码可能已变化。")
        path.write_text(result, encoding="utf-8")
        self.changed.add(rel)


def rust_str(s):
    # 对 ASCII 和普通 Unicode 字符，JSON 字符串转义与 Rust 字符串字面量兼容
    if any(ord(c) < 0x20 for c in s):
        sys.exit(f"[customize] 配置值不能包含控制字符：{s!r}")
    return json.dumps(s, ensure_ascii=False)


def rust_map(d):
    if not d:
        return "Default::default()"
    items = ", ".join(f"({rust_str(k)}.to_owned(), {rust_str(v)}.to_owned())" for k, v in d.items())
    return f"RwLock::new(HashMap::from([{items}]))"


def read_server_env():
    names = ("HOMEUU_SERVER", "HOMEUU_RELAY", "HOMEUU_KEY")
    vals = {n: os.environ.get(n, "").strip() for n in names}
    given = [n for n in names if vals[n]]
    if not given:
        print("[customize] 警告：未设置服务器信息，安装后需在客户端设置里手动填写服务器", file=sys.stderr)
        return None
    if len(given) != len(names):
        missing = ", ".join(n for n in names if not vals[n])
        sys.exit(f"[customize] 服务器信息不完整，缺少：{missing}")
    for n in ("HOMEUU_SERVER", "HOMEUU_RELAY"):
        if not re.fullmatch(r"[A-Za-z0-9.\-]+:\d{1,5}", vals[n]):
            sys.exit(f"[customize] {n} 格式应为 host:port，例如 1.2.3.4:31116")
    try:
        ok = len(base64.b64decode(vals["HOMEUU_KEY"], validate=True)) == 32
    except ValueError:
        ok = False
    if not ok:
        sys.exit("[customize] HOMEUU_KEY 应为服务器 id_ed25519.pub 的内容（44 个字符的 base64）")
    return vals


def customize(root: Path, cfg: dict):
    p = Patcher(root)
    app, org, bundle = cfg["app_name"], cfg["org"], cfg["bundle_id"]
    if not re.fullmatch(r"[a-z][a-z0-9]{2,7}", app):
        # MSI 打包按 8.3 文件名处理产品名，小写字母开头、不超过 8 个字符最稳妥
        sys.exit("[customize] app_name 需为 3–8 位小写字母或数字，且以字母开头")
    server = read_server_env()

    # ---------- 通用：hbb_common 配置常量 ----------
    conf = "libs/hbb_common/src/config.rs"
    p.sub(conf, 'RwLock::new("com.carriez".to_owned())', f"RwLock::new({rust_str(org)}.to_owned())")
    p.sub(conf, 'APP_NAME: RwLock<String> = RwLock::new("RustDesk".to_owned())',
          f"APP_NAME: RwLock<String> = RwLock::new({rust_str(app)}.to_owned())")
    p.re_sub(conf, r"pub const RENDEZVOUS_PORT: i32 = \d+;", f"pub const RENDEZVOUS_PORT: i32 = {int(cfg['rendezvous_port'])};")
    p.re_sub(conf, r"pub const RELAY_PORT: i32 = \d+;", f"pub const RELAY_PORT: i32 = {int(cfg['relay_port'])};")

    overwrite = dict(cfg.get("overwrite_settings", {}))
    if server:
        host = server["HOMEUU_SERVER"].rsplit(":", 1)[0]
        p.re_sub(conf, r'pub const RENDEZVOUS_SERVERS: &\[&str\] = &\[[^\]]*\];',
                 f"pub const RENDEZVOUS_SERVERS: &[&str] = &[{rust_str(host)}];")
        p.re_sub(conf, r'pub const RS_PUB_KEY: &str = "[^"]*";',
                 f"pub const RS_PUB_KEY: &str = {rust_str(server['HOMEUU_KEY'])};")
        # 同时写入锁定设置，旧的本地配置无法覆盖内置服务器
        overwrite.update({
            "custom-rendezvous-server": server["HOMEUU_SERVER"],
            "relay-server": server["HOMEUU_RELAY"],
            "key": server["HOMEUU_KEY"],
        })
    else:
        # 不连官方公共服务器。用一个解析不了的占位地址，列表不能为空（上游有代码直接取第 0 项）
        p.re_sub(conf, r'pub const RENDEZVOUS_SERVERS: &\[&str\] = &\[[^\]]*\];',
                 'pub const RENDEZVOUS_SERVERS: &[&str] = &["homeuu.invalid"];')
    p.sub(conf, "pub static ref OVERWRITE_SETTINGS: RwLock<HashMap<String, String>> = Default::default();",
          f"pub static ref OVERWRITE_SETTINGS: RwLock<HashMap<String, String>> = {rust_map(overwrite)};")
    p.sub(conf, "pub static ref OVERWRITE_LOCAL_SETTINGS: RwLock<HashMap<String, String>> = Default::default();",
          f"pub static ref OVERWRITE_LOCAL_SETTINGS: RwLock<HashMap<String, String>> = "
          f"{rust_map(cfg.get('overwrite_local_settings', {}))};")

    # ---------- Windows ----------
    p.sub("flutter/windows/CMakeLists.txt", 'set(BINARY_NAME "rustdesk")', f'set(BINARY_NAME "{app}")')
    rc = "flutter/windows/runner/Runner.rc"
    p.sub(rc, '"CompanyName", "Purslane Tech Pte. Ltd."', f'"CompanyName", "{cfg["manufacturer"]}"')
    p.sub(rc, '"FileDescription", "RustDesk Remote Desktop"', f'"FileDescription", "{app}"')
    p.sub(rc, '"InternalName", "rustdesk"', f'"InternalName", "{app}"')
    p.sub(rc, '"OriginalFilename", "rustdesk.exe"', f'"OriginalFilename", "{app}.exe"')
    p.sub(rc, '"ProductName", "RustDesk"', f'"ProductName", "{app}"')

    # ---------- macOS：应用名、Bundle ID ----------
    p.sub("flutter/macos/Runner/Configs/AppInfo.xcconfig", "PRODUCT_NAME = RustDesk", f"PRODUCT_NAME = {app}")
    p.sub("flutter/macos/Runner/Configs/AppInfo.xcconfig", "PRODUCT_BUNDLE_IDENTIFIER = com.carriez.flutterHbb",
          f"PRODUCT_BUNDLE_IDENTIFIER = {bundle}")
    pbx = "flutter/macos/Runner.xcodeproj/project.pbxproj"
    p.sub(pbx, "PRODUCT_BUNDLE_IDENTIFIER = com.carriez.rustdesk;", f"PRODUCT_BUNDLE_IDENTIFIER = {bundle};", count=3)
    p.sub(pbx, "RustDesk.app", f"{app}.app", count=None)
    p.sub("flutter/macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme",
          'BuildableName = "RustDesk.app"', f'BuildableName = "{app}.app"', count=None)
    # Swift 模块名跟随 PRODUCT_NAME，Nib 里引用的模块必须一致，否则启动时找不到 AppDelegate
    p.sub("flutter/macos/Runner/Base.lproj/MainMenu.xib", 'customModule="RustDesk"', f'customModule="{app}"', count=2)
    plist = "flutter/macos/Runner/Info.plist"
    p.sub(plist, "<string>com.carriez.rustdesk</string>", f"<string>{bundle}</string>")
    p.sub(plist, "<string>rustdesk</string>", f"<string>{app}</string>")
    p.sub("build.py", "Release/RustDesk.app/Contents/MacOS/", f"Release/{app}.app/Contents/MacOS/")

    # ---------- macOS：launchd 标签与组织前缀 ----------
    # 上游一部分代码用 ORG 拼标签（get_full_name），一部分写死 com.carriez，
    # ORG 改了以后两边必须一起改，否则安装检测、升级、卸载会找错服务。
    p.sub("src/platform/macos.rs", '"/Library/LaunchDaemons/com.carriez.{}_service.plist"',
          f'"/Library/LaunchDaemons/{org}.{{}}_service.plist"', count=None)
    p.sub("src/platform/macos.rs", '"/Library/LaunchAgents/com.carriez.{}_server.plist"',
          f'"/Library/LaunchAgents/{org}.{{}}_server.plist"', count=None)
    p.sub("src/platform/macos.rs", 'format!("com.carriez.{}_service", app_name)',
          f'format!("{org}.{{}}_service", app_name)')
    p.sub("src/platform/macos.rs", 'format!("com.carriez.{}_server", app_name)',
          f'format!("{org}.{{}}_server", app_name)')
    # 模板里的 RustDesk 会在运行时由 correct_app_name() 换成 APP_NAME，这里只换组织前缀
    for f in ("daemon.plist", "agent.plist", "install.scpt", "uninstall.scpt", "update.scpt"):
        p.sub(f"src/platform/privileges_scripts/{f}", "com.carriez.RustDesk", f"{org}.RustDesk", count=None)

    verify_mac_labels(root, org)
    return sorted(p.changed)


def verify_mac_labels(root: Path, org: str):
    """macos.rs 里除测试和 Bundle ID 模板外，不应再出现 com.carriez。"""
    text = (root / "src/platform/macos.rs").read_text(encoding="utf-8")
    text = text.split("#[cfg(test)]")[0]
    left = [line.strip() for line in text.splitlines()
            if "com.carriez" in line and "com.carriez.rustdesk" not in line]
    if left:
        sys.exit("[customize] macos.rs 仍有未替换的 com.carriez：\n  " + "\n  ".join(left))
    for f in (root / "src/platform/privileges_scripts").iterdir():
        if "com.carriez.RustDesk" in f.read_text(encoding="utf-8"):
            sys.exit(f"[customize] {f.name} 仍有未替换的 com.carriez.RustDesk")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("rustdesk_dir", type=Path)
    ap.add_argument("--config", type=Path, default=HERE / "homeuu.json")
    args = ap.parse_args()
    cfg = json.loads(args.config.read_text(encoding="utf-8"))
    changed = customize(args.rustdesk_dir.resolve(), cfg)
    print("[customize] 已修改：")
    for f in changed:
        print("  " + f)


if __name__ == "__main__":
    main()
