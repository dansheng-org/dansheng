"""Check the actual product zip, its Gradle-consumed native AAR and runtime ELF alignment."""
import argparse
import hashlib
import json
import struct
from pathlib import Path
from zipfile import ZipFile


def sha(data):
    return hashlib.sha256(data).hexdigest()


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
    args = p.parse_args()
    native = Path(__file__).resolve().parents[1] / ".local/native"
    receipt = json.loads((native/"receipt.json").read_text(encoding="utf-8-sig"))
    aar = native/"dansheng-android-0.1.0.aar"
    if sha(aar.read_bytes()) != receipt["aar_sha256"].lower():
        raise ValueError("Gradle input AAR differs from build receipt")
    with ZipFile(args.apk) as pkg, ZipFile(aar) as reference:
        names = pkg.namelist()
        if not {"assets/COPYING.txt", "assets/NATIVE-NOTICES.txt"} <= set(names):
            raise ValueError("native licenses missing from APK")
        if len(names) != len(set(names)) or pkg.testzip():
            raise ValueError("invalid or duplicate APK entry")
        builtin="assets/builtin-venues/"
        official=Path(__file__).resolve().parents[2]/"dansheng/plugins/builtin/fudan-venues"
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
              "abi":args.abi,"release":args.release,"receipt":receipt,"libraries":checked}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(report,indent=2)+"\n",encoding="utf8")
    print(f"{args.apk.name}: {args.abi}, {len(checked)} libraries, SHA256 {report['sha256']}")


if __name__ == "__main__":
    main()
