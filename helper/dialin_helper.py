#!/usr/bin/env python3
"""Dial-in helper: runs the dial-in sheet beside PrusaSlicer.

Serves wizard/index.html at http://127.0.0.1:8765, installs the plugin bundle
into PrusaSlicer's user plugins folder, writes profile.lua into it from the
sheet, launches PrusaSlicer as a child process and streams its output to the
sheet so the plugin's numbers and errors show up there.

Standard library only. Python 3.8 or newer.

    python3 helper/dialin_helper.py                # auto-detect everything
    python helper\\dialin_helper.py --prusaslicer "C:\\Users\\me\\Downloads\\PrusaSlicer-3.0.0-alpha11\\PrusaSlicer-3.0.0-alpha11"
    python3 helper/dialin_helper.py --plugins-dir ~/.config/PrusaSlicer-alpha/lua

--prusaslicer accepts the executable or the folder it lives in (a portable
zip unpacked anywhere). On Windows the console executable is used so the
plugin's output can be captured.
"""
import argparse
import collections
import json
import os
import platform
import queue
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import webbrowser
import zipfile
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BUNDLE_ID = "com.ripleydynamics.filament-dialin"
PREFIX = "[filament-dialin] "
HERE = Path(__file__).resolve().parent
REPO = HERE.parent
SHEET = REPO / "wizard" / "index.html"
BUNDLE_SRC = REPO / BUNDLE_ID
HELPER_FILE = Path(__file__).resolve()
HELPER_NEW = HELPER_FILE.parent / (HELPER_FILE.name + ".new")

GITHUB_REPO = "Ripley-Dynamics/PrusaSlicer-3.0-Calibration-Suite"
GITHUB_BRANCH = "main"
ZIP_URL = f"https://codeload.github.com/{GITHUB_REPO}/zip/refs/heads/{GITHUB_BRANCH}"
COMMITS_URL = f"https://api.github.com/repos/{GITHUB_REPO}/commits/{GITHUB_BRANCH}"
USER_AGENT = "dialin-helper"
COPY_IGNORE = shutil.ignore_patterns("*.pyc", ".DS_Store", "__pycache__")
KEEP_FILE = "profile.lua"          # never overwritten by an install or an update
STAMP_FILE = "INSTALLED.json"      # written into the installed bundle by an update
REFRESHED = ["wizard/index.html", "README.md"]   # refreshed in this checkout too


# ---------------------------------------------------------------- locations
def config_path():
    if platform.system() == "Windows":
        base = Path(os.environ.get("APPDATA", Path.home()))
    else:
        base = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return base / "dialin-helper.json"


def load_config():
    try:
        return json.loads(config_path().read_text())
    except Exception:
        return {}


def save_config(cfg):
    try:
        config_path().parent.mkdir(parents=True, exist_ok=True)
        config_path().write_text(json.dumps(cfg, indent=2))
    except Exception as e:
        print("could not save config:", e)


def data_dir_candidates():
    """PrusaSlicer user data directories, alpha/beta builds first."""
    system = platform.system()
    names = ["PrusaSlicer-alpha", "PrusaSlicer-beta", "PrusaSlicer"]
    if system == "Windows":
        base = Path(os.environ.get("APPDATA", Path.home()))
        return [base / n for n in names]
    if system == "Darwin":
        base = Path.home() / "Library" / "Application Support"
        return [base / n for n in names]
    base = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return [base / n for n in names]


def resolve_plugins_dir(path):
    """Accepts the plugins folder itself (Plugins > Show User Plugins Folder) or
    PrusaSlicer's user data folder, in which case the 'lua' subfolder is used."""
    if not path:
        return None
    p = Path(str(path).strip().strip('"')).expanduser()
    if p.name.lower() != "lua" and (p / "lua").is_dir():
        return p / "lua"
    if p.name.lower() != "lua" and p.is_dir() and (p / "PrusaSlicer.ini").exists():
        return p / "lua"
    return p


def detect_plugins_dir():
    for d in data_dir_candidates():
        if d.is_dir():
            return d / "lua"
    return None


WINDOWS_EXES = ["prusa-slicer-console.exe", "prusaslicer-console.exe", "prusaslicer.exe", "prusa-slicer.exe"]


def resolve_executable(path):
    """Accepts an executable or a folder (portable zip) and returns the executable."""
    if not path:
        return None
    p = Path(path).expanduser()
    if p.is_dir():
        names = WINDOWS_EXES if platform.system() == "Windows" else ["prusa-slicer", "PrusaSlicer", "PrusaSlicer.app/Contents/MacOS/PrusaSlicer"]
        for name in names:
            for candidate in [p / name] + sorted(p.glob(f"*/{name}"))[:5]:
                if candidate.exists():
                    return str(candidate)
        return None
    if platform.system() == "Windows" and p.suffix.lower() == ".exe" and "console" not in p.name.lower():
        console = p.parent / p.name.lower().replace(".exe", "-console.exe")
        if console.exists():
            return str(console)
    return str(p) if p.exists() else None


def detect_prusaslicer():
    system = platform.system()
    candidates = []
    if system == "Windows":
        for root in [os.environ.get("ProgramFiles", r"C:\Program Files"), os.environ.get("LOCALAPPDATA", "")]:
            if root:
                candidates += [
                    Path(root) / "Prusa3D" / "PrusaSlicer" / "prusa-slicer-console.exe",
                    Path(root) / "Prusa3D" / "PrusaSlicer-alpha" / "prusa-slicer-console.exe",
                    Path(root) / "Programs" / "PrusaSlicer" / "prusa-slicer-console.exe",
                ]
        # Portable zips unpacked in Downloads or Desktop: newest alpha/beta folder first.
        for base in [Path.home() / "Downloads", Path.home() / "Desktop", Path.home()]:
            found = sorted(base.glob("PrusaSlicer*/prusa-slicer-console.exe")) + sorted(base.glob("PrusaSlicer*/*/prusa-slicer-console.exe"))
            candidates += sorted(found, key=lambda x: str(x).lower(), reverse=True)
    elif system == "Darwin":
        for app in ["PrusaSlicer-alpha", "PrusaSlicer-beta", "PrusaSlicer"]:
            candidates += [Path("/Applications") / f"{app}.app" / "Contents" / "MacOS" / "PrusaSlicer",
                           Path.home() / "Applications" / f"{app}.app" / "Contents" / "MacOS" / "PrusaSlicer"]
    else:
        for name in ["prusa-slicer", "PrusaSlicer", "prusa-slicer-alpha"]:
            found = shutil.which(name)
            if found:
                candidates.append(Path(found))
        candidates += sorted(Path.home().glob("**/PrusaSlicer*.AppImage"))[:3]
    for c in candidates:
        if c and Path(c).exists():
            return str(c)
    return None


# ---------------------------------------------------------------- github
def http_get(url, timeout=60, accept="*/*"):
    """GET a URL with urllib, which honours the environment's proxy settings."""
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": accept})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def latest_commit():
    """sha, date and subject of the branch head. Unauthenticated and
    rate-limited, so a failure here only costs the decoration."""
    blank = {"commit": None, "commit_date": None, "commit_message": None}
    try:
        j = json.loads(http_get(COMMITS_URL, timeout=20, accept="application/vnd.github+json").decode("utf-8", "replace"))
        commit = j.get("commit") or {}
        message = (commit.get("message") or "").splitlines()
        return {"commit": j.get("sha") or None,
                "commit_date": (commit.get("committer") or {}).get("date"),
                "commit_message": message[0] if message else None}
    except Exception:
        return blank


def read_bytes(path):
    try:
        return Path(path).read_bytes()
    except Exception:
        return None


def dir_files(folder, skip=()):
    folder = Path(folder)
    return {p.relative_to(folder).as_posix(): p
            for p in folder.rglob("*") if p.is_file() and p.name not in skip}


def dirs_differ(a, b, skip=()):
    """True when the two folders hold a different set of files, or different
    bytes in any of them (skip names that belong to the installed copy)."""
    fa, fb = dir_files(a, skip), dir_files(b, skip)
    if set(fa) != set(fb):
        return True
    return any(fa[k].read_bytes() != fb[k].read_bytes() for k in fa)


def copy_bundle(src, dst):
    """Replace the bundle folder dst with src, keeping dst's profile.lua.
    Returns True when a profile.lua was carried over."""
    src, dst = Path(src), Path(dst)
    keep = read_bytes(dst / KEEP_FILE) if (dst / KEEP_FILE).exists() else None
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst, ignore=COPY_IGNORE)
    if keep is not None:
        (dst / KEEP_FILE).write_bytes(keep)
    return keep is not None


# ---------------------------------------------------------------- state
class Helper:
    def __init__(self, args):
        cfg = load_config()
        self.plugins_dir = resolve_plugins_dir(args.plugins_dir) or resolve_plugins_dir(cfg.get("plugins_dir")) or detect_plugins_dir() or Path("")
        self.prusaslicer = resolve_executable(args.prusaslicer) or resolve_executable(cfg.get("prusaslicer")) or detect_prusaslicer()
        if args.prusaslicer and not self.prusaslicer:
            print(f"warning: no PrusaSlicer executable found at {args.prusaslicer}")
        self.process = None
        self.events = collections.deque(maxlen=500)
        self.clients = []
        self.lock = threading.Lock()
        self.seq = 0
        self._helper_outdated = False
        save_config({"plugins_dir": str(self.plugins_dir) if self.plugins_dir_set() else "", "prusaslicer": self.prusaslicer or ""})

    # -- bundle
    def plugins_dir_set(self):
        """Whether a plugins folder is known. Path("") is PosixPath("."), so an
        unset folder is not simply falsy."""
        return str(self.plugins_dir) not in ("", ".")

    def require_plugins_dir(self):
        if not self.plugins_dir_set():
            raise RuntimeError("No PrusaSlicer user data folder found. Start PrusaSlicer 3.0 once, or pass --plugins-dir.")

    @property
    def bundle_dst(self):
        return self.plugins_dir / BUNDLE_ID if self.plugins_dir_set() else None

    def manifest_version(self, folder):
        try:
            return json.loads((folder / "manifest.json").read_text()).get("version")
        except Exception:
            return None

    def installed_stamp(self):
        """INSTALLED.json from the installed bundle, written by an update."""
        dst = self.bundle_dst
        try:
            return json.loads((dst / STAMP_FILE).read_text())
        except Exception:
            return {}

    def helper_outdated(self):
        """True when an update found a newer helper program than the one that is
        running, and the replacement is still waiting as dialin_helper.py.new."""
        if not HELPER_NEW.exists():
            return self._helper_outdated
        new = read_bytes(HELPER_NEW)
        return new is not None and new != read_bytes(HELPER_FILE)

    def status(self):
        dst = self.bundle_dst
        stamp = self.installed_stamp()
        commit = stamp.get("commit") or None
        return {
            "helper": True,
            "version": 1,
            "platform": platform.system(),
            "repo": str(REPO),
            "plugins_dir": str(self.plugins_dir) if self.plugins_dir_set() else None,
            "plugins_dir_exists": self.plugins_dir_set() and self.plugins_dir.parent.is_dir(),
            "bundle_source_version": self.manifest_version(BUNDLE_SRC),
            "bundle_installed_version": self.manifest_version(dst) if dst else None,
            "bundle_installed_commit": commit[:7] if isinstance(commit, str) else None,
            "bundle_installed_at": stamp.get("installed_at"),
            "helper_outdated": self.helper_outdated(),
            "profile_exists": bool(dst) and (dst / "profile.lua").exists(),
            "prusaslicer": self.prusaslicer,
            "prusaslicer_exists": bool(self.prusaslicer) and Path(self.prusaslicer).exists(),
            "running": self.process is not None and self.process.poll() is None,
            "looks_like_2x": bool(self.prusaslicer) and not re.search(r"3\.0|alpha|beta", self.prusaslicer, re.I),
            "events": len(self.events),
        }

    def _install_from(self, src_dir):
        """Put src_dir into the plugins folder as the installed bundle, keeping
        the profile.lua already there. Shared by install() and the GitHub path."""
        self.require_plugins_dir()
        src_dir = Path(src_dir)
        if not src_dir.is_dir():
            raise RuntimeError(f"Bundle source missing: {src_dir}")
        dst = self.bundle_dst
        self.plugins_dir.mkdir(parents=True, exist_ok=True)
        kept = copy_bundle(src_dir, dst)
        return dst, kept

    def install(self):
        dst, _ = self._install_from(BUNDLE_SRC)
        self.emit("helper", f"installed bundle {self.manifest_version(dst)} into {dst}")
        return str(dst)

    def update_from_github(self):
        """Download the branch zip from GitHub, install the bundle out of it and
        refresh this checkout (bundle, sheet, README) so the served sheet matches
        what is installed. The running helper program is never replaced."""
        self.require_plugins_dir()
        was = self.installed_stamp().get("commit")
        tmp = Path(tempfile.mkdtemp(prefix="dialin-update-"))
        try:
            zip_path = tmp / "main.zip"
            zip_path.write_bytes(http_get(ZIP_URL, timeout=60))
            src = tmp / "src"
            with zipfile.ZipFile(zip_path) as zf:
                names = [n for n in zf.namelist() if n.strip("/")]
                tops = sorted({n.split("/")[0] for n in names})
                if len(tops) != 1:
                    raise RuntimeError(f"unexpected zip from {ZIP_URL}: top-level entries {tops}")
                top = tops[0]
                if f"{top}/{BUNDLE_ID}/manifest.json" not in names:
                    raise RuntimeError(f"the zip from {ZIP_URL} has no {top}/{BUNDLE_ID}/manifest.json "
                                       f"-- wrong branch, or the bundle folder moved in the repo")
                wanted = [f"{top}/helper/{HELPER_FILE.name}"] + [f"{top}/{r}" for r in REFRESHED]
                members = [n for n in names if not n.endswith("/")
                           and (n.startswith(f"{top}/{BUNDLE_ID}/") or n in wanted)]
                zf.extractall(src, members=members)
            new_bundle = src / top / BUNDLE_ID
            version = self.manifest_version(new_bundle)

            dst, kept = self._install_from(new_bundle)

            changed, checkout_error = [], None
            try:
                if not BUNDLE_SRC.is_dir() or dirs_differ(new_bundle, BUNDLE_SRC, skip=(KEEP_FILE, STAMP_FILE)):
                    changed.append(BUNDLE_ID)
                copy_bundle(new_bundle, BUNDLE_SRC)
                for rel in REFRESHED:
                    got = src / top / rel
                    if not got.is_file():
                        continue
                    if read_bytes(got) != read_bytes(REPO / rel):
                        (REPO / rel).parent.mkdir(parents=True, exist_ok=True)
                        (REPO / rel).write_bytes(got.read_bytes())
                        changed.append(rel)
            except Exception as e:
                checkout_error = f"could not refresh {REPO}: {e}"

            # The running program cannot replace itself: leave the new one beside it.
            new_helper = src / top / "helper" / HELPER_FILE.name
            outdated = new_helper.is_file() and read_bytes(new_helper) != read_bytes(HELPER_FILE)
            if outdated:
                try:
                    HELPER_NEW.write_bytes(new_helper.read_bytes())
                except Exception as e:
                    checkout_error = checkout_error or f"could not write {HELPER_NEW}: {e}"
            self._helper_outdated = bool(outdated)

            head = latest_commit()
            short = (head["commit"] or "")[:7] or None
            day = (head["commit_date"] or "")[:10] or None
            installed_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
            stamp = {"source": ZIP_URL, "commit": head["commit"], "commit_date": head["commit_date"],
                     "installed_at": installed_at, "version": version}
            (dst / STAMP_FILE).write_text(json.dumps(stamp, indent=2))

            same = bool(head["commit"] and was and head["commit"] == was)
            line = (f"loaded latest plugin: v{version or '?'}, commit {short or 'unknown'}"
                    f"{f' ({day})' if day else ''} into {dst}")
            if same:
                line += f"; already at commit {short}, reinstalled"
            if kept:
                line += "; kept profile.lua"
            self.emit("helper", line)
            if outdated:
                self.emit("helper", f"the download's helper program differs from the running one: wrote it beside "
                                    f"this one as {HELPER_NEW.name} -- close the helper, replace {HELPER_FILE.name} "
                                    f"with it and start it again")
            if checkout_error:
                self.emit("warning", checkout_error)
            return {
                "source": ZIP_URL,
                "version": version,
                "commit": head["commit"],
                "commit_short": short,
                "commit_date": head["commit_date"],
                "commit_message": head["commit_message"],
                "installed_to": str(dst),
                "installed_at": installed_at,
                "profile_kept": bool(kept),
                "same_commit": same,
                "files_changed": changed,
                "changed": bool(changed),
                "helper_outdated": bool(outdated),
                "helper_new_path": str(HELPER_NEW) if outdated else None,
                "checkout_error": checkout_error,
                "line": line,
            }
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def write_profile(self, lua):
        if not lua.strip().startswith("--") and not lua.strip().startswith("return"):
            raise RuntimeError("profile.lua must be a Lua chunk returning a table")
        dst = self.bundle_dst
        if not dst or not dst.is_dir():
            self.install()
            dst = self.bundle_dst
        (dst / "profile.lua").write_text(lua)
        self.emit("helper", f"wrote profile.lua ({len(lua)} bytes); a running PrusaSlicer picks it up on the next Run, no rescan needed")
        return str(dst / "profile.lua")

    # -- process
    def launch(self):
        if self.process is not None and self.process.poll() is None:
            return "already running"
        if not self.prusaslicer or not Path(self.prusaslicer).exists():
            raise RuntimeError("PrusaSlicer executable not found. Pass --prusaslicer PATH (on Windows use prusa-slicer-console.exe).")
        self.process = subprocess.Popen([self.prusaslicer], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                        text=True, bufsize=1, errors="replace")
        threading.Thread(target=self._reader, daemon=True).start()
        self.emit("helper", f"launched {self.prusaslicer} (pid {self.process.pid})")
        return "launched"

    def _reader(self):
        proc = self.process
        for raw in proc.stdout:
            self.ingest(raw.rstrip("\r\n"))
        code = proc.wait()
        note = ""
        if code == 3221226505 or code == -1073740791:
            note = " (0xC0000409, a Windows fail-fast crash inside PrusaSlicer; note what you did last)"
        self.emit("helper", f"PrusaSlicer exited with code {code}{note}")

    def ingest(self, line):
        if PREFIX in line:
            body = line.split(PREFIX, 1)[1]
            if body.startswith("DATA "):
                self.emit("data", body, parse_data(body[5:]))
            elif body.lower().startswith("warning") or "could not set" in body:
                self.emit("warning", body)
            else:
                self.emit("plugin", body)
        elif "may not be an error" in line or "not a plugin but shared module" in line:
            self.emit("slicer", line)  # PrusaSlicer's routine note about helper modules
        elif re.search(r"\b(lua|plugin)\b", line, re.I) and re.search(r"error|fail|exception|cannot|invalid", line, re.I):
            self.emit("error", line)
        elif re.search(r"exited with code|crash|assert", line, re.I):
            self.emit("warning", line)
        else:
            self.emit("slicer", line)

    # -- events
    def emit(self, kind, text, data=None):
        with self.lock:
            self.seq += 1
            ev = {"id": self.seq, "ts": time.time(), "kind": kind, "text": text}
            if data is not None:
                ev["data"] = data
            self.events.append(ev)
            for q in list(self.clients):
                q.put(ev)
        if kind != "slicer":
            print(f"{kind:8} {text}")

    def subscribe(self, since):
        q = queue.Queue()
        with self.lock:
            backlog = [e for e in self.events if e["id"] > since]
            self.clients.append(q)
        return q, backlog

    def unsubscribe(self, q):
        with self.lock:
            if q in self.clients:
                self.clients.remove(q)


DATA_RE = re.compile(r'(\w+)=("(?:[^"\\]|\\.)*"|\S+)')


def parse_data(body):
    out = {}
    for key, val in DATA_RE.findall(body):
        if val.startswith('"'):
            out[key] = val[1:-1].replace('\\"', '"').replace("\\\\", "\\")
        elif val in ("true", "false"):
            out[key] = val == "true"
        else:
            try:
                out[key] = float(val) if ("." in val or "e" in val) else int(val)
            except ValueError:
                out[key] = val
    return out


# ---------------------------------------------------------------- http
class Handler(BaseHTTPRequestHandler):
    helper = None  # set at startup

    def log_message(self, fmt, *args):
        pass

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def do_GET(self):
        h = self.helper
        if self.path in ("/", "/index.html"):
            try:
                body = SHEET.read_bytes()
            except Exception:
                self.send_error(404, "wizard/index.html not found next to the helper")
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/api/status":
            self._json(h.status())
        elif self.path.startswith("/api/log"):
            since = 0
            m = re.search(r"since=(\d+)", self.path)
            if m:
                since = int(m.group(1))
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            q, backlog = h.subscribe(since)
            try:
                for ev in backlog:
                    self._sse(ev)
                while True:
                    try:
                        ev = q.get(timeout=15)
                        self._sse(ev)
                    except queue.Empty:
                        self.wfile.write(b": keepalive\n\n")
                        self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            finally:
                h.unsubscribe(q)
        else:
            self.send_error(404)

    def _sse(self, ev):
        self.wfile.write(f"id: {ev['id']}\ndata: {json.dumps(ev)}\n\n".encode())
        self.wfile.flush()

    def do_POST(self):
        h = self.helper
        try:
            if self.path == "/api/install":
                self._json({"ok": True, "path": h.install(), "status": h.status()})
            elif self.path == "/api/update":
                self._json({"ok": True, "result": h.update_from_github(), "status": h.status()})
            elif self.path == "/api/profile":
                self._json({"ok": True, "path": h.write_profile(self._body().get("lua", "")), "status": h.status()})
            elif self.path == "/api/launch":
                self._json({"ok": True, "result": h.launch(), "status": h.status()})
            elif self.path == "/api/config":
                b = self._body()
                errors = []
                if b.get("plugins_dir"):
                    h.plugins_dir = resolve_plugins_dir(b["plugins_dir"])
                if b.get("prusaslicer"):
                    exe = resolve_executable(b["prusaslicer"])
                    if exe:
                        h.prusaslicer = exe
                    else:
                        errors.append(f"no PrusaSlicer executable found at {b['prusaslicer']}")
                if errors:
                    raise RuntimeError("; ".join(errors))
                save_config({"plugins_dir": str(h.plugins_dir), "prusaslicer": h.prusaslicer or ""})
                self._json({"ok": True, "status": h.status()})
            elif self.path == "/api/test-line":
                h.ingest(self._body().get("line", ""))
                self._json({"ok": True})
            else:
                self.send_error(404)
        except Exception as e:
            self._json({"ok": False, "error": str(e), "status": h.status()}, 400)


def main():
    ap = argparse.ArgumentParser(description="Run the dial-in sheet beside PrusaSlicer.")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--plugins-dir", help="PrusaSlicer user plugins folder (Plugins > Show User Plugins Folder)")
    ap.add_argument("--prusaslicer", help="PrusaSlicer executable, or the folder of a portable zip")
    ap.add_argument("--no-browser", action="store_true")
    ap.add_argument("--launch", action="store_true", help="launch PrusaSlicer immediately")
    ap.add_argument("--update", action="store_true",
                    help="fetch the latest plugin from GitHub, install it and exit")
    args = ap.parse_args()

    Handler.helper = Helper(args)
    if args.update:
        try:
            print(json.dumps(Handler.helper.update_from_github(), indent=2))
        except Exception as e:
            print("update failed:", e)
            sys.exit(1)
        return
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    url = f"http://127.0.0.1:{args.port}/"
    st = Handler.helper.status()
    print(f"dial-in helper at {url}")
    print(f"  plugins folder : {st['plugins_dir'] or 'not found (pass --plugins-dir)'}")
    print(f"  bundle         : source {st['bundle_source_version']}, installed {st['bundle_installed_version'] or 'no'}")
    print(f"  PrusaSlicer    : {st['prusaslicer'] or 'not found (pass --prusaslicer)'}")
    if args.launch:
        try:
            Handler.helper.launch()
        except Exception as e:
            print("launch failed:", e)
    if not args.no_browser:
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        p = Handler.helper.process
        if p is not None and p.poll() is None:
            print("PrusaSlicer is still running; leaving it open")


if __name__ == "__main__":
    main()
