"""Check the actual product zip, its Gradle-consumed native AAR and runtime ELF alignment."""
import argparse
import hashlib
import json
import os
import struct
from pathlib import Path
from zipfile import ZipFile


def sha(data):
    return hashlib.sha256(data).hexdigest()


def app_relative_path(app, explicit, environment, fallback):
    """Resolve the same App-root-relative overrides used by the build scripts."""
    value = explicit or os.environ.get(environment)
    candidate = Path(value) if value else fallback
    return (candidate if candidate.is_absolute() else app / candidate).resolve()


def default_core_path(app):
    candidates = []
    if app.name.lower() == "app":
        candidates.append(app.parent / "core")
    candidates.extend((app.parent / "dansheng-core", app.parent / "dansheng"))
    return next((candidate for candidate in candidates
                 if (candidate / "Cargo.toml").is_file()
                 and (candidate / "include/dansheng.h").is_file()),
                app.parent / "dansheng-core")


def load_segments(data):
    if data[:6] != b"\x7fELF\x02\x01":
        raise ValueError("expected little endian ELF64")
    offset = struct.unpack_from("<Q", data, 32)[0]
    size, count = struct.unpack_from("<HH", data, 54)
    return [struct.unpack_from("<Q", data, offset + i*size + 48)[0]
            for i in range(count) if struct.unpack_from("<I", data, offset + i*size)[0] == 1]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("apk", type=Path)
    p.add_argument("--abi", required=True, choices=["arm64-v8a", "x86_64"])
    p.add_argument("--release", action="store_true")
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--core-root", type=Path,
                   help="Core checkout; defaults to DANSHENG_CORE_ROOT, paired core, or sibling dansheng-core")
    p.add_argument("--artifact-directory", type=Path,
                   help="Native SDK directory; defaults to DANSHENG_CORE_SDK_DIR or App .local/native")
    p.add_argument("--lock-file", type=Path, help="Core lock; defaults to App core.lock.json")
    args = p.parse_args()
    app = Path(__file__).resolve().parents[1]
    core = app_relative_path(app, args.core_root, "DANSHENG_CORE_ROOT", default_core_path(app))
    native = app_relative_path(app, args.artifact_directory, "DANSHENG_CORE_SDK_DIR", app / ".local/native")
    lock_path = app_relative_path(app, args.lock_file, "DANSHENG_CORE_LOCK_FILE", app / "core.lock.json")
    lock = json.loads(lock_path.read_text(encoding="utf-8-sig")) if lock_path.is_file() else None
    if lock and (lock.get("format") != "dansheng-core-lock-v1" or lock.get("mode") != "native-sdk"):
        raise ValueError("unsupported Core dependency lock")
    receipt_path = native/"receipt.json"
    receipt = json.loads(receipt_path.read_text(encoding="utf-8-sig")) if receipt_path.is_file() else None
    name = lock["artifact"]["name"] if lock else "dansheng-android-0.1.0.aar"
    if not name or name in (".", "..") or "/" in name or "\\" in name:
        raise ValueError("unsafe native artifact name")
    aar = native/name
    expected_hash = lock["artifact"]["sha256"] if lock else (receipt or {}).get("aar_sha256")
    if not expected_hash or sha(aar.read_bytes()) != expected_hash.lower():
        raise ValueError("Gradle input AAR differs from build receipt")
    if receipt and sha(aar.read_bytes()) != receipt["aar_sha256"].lower():
        raise ValueError("native receipt and selected AAR disagree")
    with ZipFile(args.apk) as pkg, ZipFile(aar) as reference:
        names = pkg.namelist()
        if not {"assets/COPYING.txt", "assets/NATIVE-NOTICES.txt"} <= set(names):
            raise ValueError("native licenses missing from APK")
        if len(names) != len(set(names)) or pkg.testzip():
            raise ValueError("invalid or duplicate APK entry")
        builtin="assets/builtin-venues/"
        resources = core if (core/"Cargo.toml").is_file() else native/"resources"
        official=resources/"plugins/builtin/fudan-venues"
        modules={"main.mjs","api.mjs","policy.mjs"}
        if any("fudan-sports" in n or "closed-loop" in n or n.rsplit("/",1)[-1].lower()=="credentials.txt" or n.endswith((".dspack",".jks",".p12")) or
               (n.endswith(".mjs") and n not in {builtin+s for s in modules}) for n in names):
            raise ValueError("unexpected external automation, private key or fixture in client")
        for part in modules|{"manifest.json","host-policy.json","NOTICE.md"}:
            if pkg.read(builtin+part)!=(official/part).read_bytes():
                raise ValueError("APK manual venue component differs from official source: "+part)
        manifest=json.loads(pkg.read(builtin+"manifest.json"))
        if manifest["id"]!="official.fudan-venues" or any(c.startswith("jobs.") for c in manifest["capabilities"]):
            raise ValueError("built-in manual booking must not schedule jobs")
        for n in names:
            if n.endswith((".dex",".so","kernel_blob.bin")):
                binary=pkg.read(n)
                for marker in [b"fixture.closed-loop",b"org/dansheng/app/checks/ProductRunner"]:
                    if marker in binary:raise ValueError(f"plugin/test code found in {n}: {marker!r}")
        libs = [n for n in names if n.startswith("lib/") and n.endswith(".so")]
        required = {"libflutter.so", "libdansheng_android.so", "libdansheng_ffi.so"}
        if args.release:
            required.add("libapp.so")
        selected = {Path(n).name for n in libs if n.startswith("lib/"+args.abi+"/")}
        if not required <= selected:
            raise ValueError(f"incomplete native ABI: missing {required-selected}")
        if args.release and any(n.split("/")[1] != args.abi for n in libs):
            raise ValueError("release APK is not ABI-specific")
        checked = {}
        for name in libs:
            data = pkg.read(name)
            aligns = load_segments(data)
            if not aligns or min(aligns) < 16384:
                raise ValueError("not 16 KiB ELF aligned: "+name)
            filename = Path(name).name
            if filename in {"libdansheng_android.so", "libdansheng_ffi.so"}:
                if data != reference.read("jni/"+name[4:]):
                    raise ValueError("APK native library differs from AAR: "+name)
            checked[name] = {"sha256":sha(data),"minimum_load_alignment":min(aligns)}
    report = {"apk":args.apk.name,"sha256":sha(args.apk.read_bytes()),"bytes":args.apk.stat().st_size,
              "abi":args.abi,"release":args.release,"receipt":receipt,"libraries":checked,
              "core_dependency": {"state":lock["state"], "commit":lock["core"]["commit"]} if lock else {"state":"legacy_native_receipt"}}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(report,indent=2)+"\n",encoding="utf8")
    print(f"{args.apk.name}: {args.abi}, {len(checked)} libraries, SHA256 {report['sha256']}")


if __name__ == "__main__":
    main()
