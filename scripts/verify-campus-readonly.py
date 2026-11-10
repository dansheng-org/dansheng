"""Explicit real-account acceptance on a throwaway AVD. No writes to school services."""
import argparse,concurrent.futures,hashlib,hmac,json,re,secrets,socket,subprocess
from pathlib import Path

def credentials(path):
    keys={"user","password","danxiuser","danxipassword","canvastoken"}
    values={}
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        match=re.fullmatch(r"\s*([A-Za-z]+)\s*[:=：]\s*(.*?)\s*",line)
        if not match:continue
        key,raw=match[1].lower(),match[2].removesuffix(",").strip()
        if key in keys:
            value=raw[1:-1] if len(raw)>=2 and raw[0]==raw[-1] and raw[0] in "'\"" else raw
            if key in values or not value:raise ValueError("Duplicate or empty credential field")
            values[key]=value
    if keys!=values.keys():raise ValueError("Missing credential fields")
    if not values["user"].isdigit() or not re.fullmatch(r"[^@\s]+@(?:m\.)?fudan\.edu\.cn",values["danxiuser"],re.I):
        raise ValueError("Expected a campus account and registered forum email")
    return json.dumps(values,ensure_ascii=False).encode()

def run():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--credentials",type=Path,required=True);p.add_argument("--output",type=Path,required=True)
    p.add_argument("--adb",default="adb");p.add_argument("--serial",default="emulator-5592")
    p.add_argument("--apk",type=Path,help="Exact APK under test (defaults to the distribution build)")
    p.add_argument("--ehall-ui",action="store_true",help="Exercise eHall read-only navigation using the active QA account")
    p.add_argument("--inspect-power",action="store_true",help="Report only safe field types from the dorm response")
    p.add_argument("--inspect-file",action="store_true",help="Report only file metadata status and classified download origin")
    p.add_argument("--inspect-venue",action="store_true",help="Only verify saved UIS and a read-only sports login")
    p.add_argument("--foreground-venue",action="store_true",help="Exercise the real visible venue authentication window")
    args=p.parse_args()
    adb=lambda *cmd,timeout=520:subprocess.run([args.adb,"-s",args.serial,*cmd],capture_output=True,timeout=timeout,check=True).stdout.decode(errors="replace")
    if not re.fullmatch(r"emulator-\d+",args.serial) or adb("emu","avd","name").splitlines()[0]!="dansheng-app-api36":
        raise SystemExit("Select the disposable dansheng-app-api36 AVD")
    root=Path(__file__).resolve().parents[1]
    marker=(root/".local/repair-avd-path.txt").read_text(encoding="utf8").strip()
    # A matching AVD name alone is not sufficient authorization to use credentials.
    own=Path(marker).resolve()
    if own.parent!=(root/".local").resolve() or not own.name.startswith("repair-avd-") or not own.is_dir():
        raise SystemExit("Missing disposable AVD receipt")
    if adb("shell","cat","/data/local/tmp/dansheng-qa-target-id").strip()!=own.name:
        raise SystemExit("Emulator does not match disposable AVD receipt")
    def installed_hash(name):
        lines=adb("shell","pm","path",name).splitlines()
        if len(lines)!=1 or not lines[0].startswith("package:/data/app/"):raise RuntimeError("Unexpected installed APK layout")
        digest=adb("shell","sha256sum",lines[0].removeprefix("package:")).split()[0].lower()
        if not re.fullmatch("[0-9a-f]{64}",digest):raise RuntimeError("Missing device hash")
        return digest
    client=installed_hash("org.dansheng.app")
    if not args.inspect_power:
        with (args.apk or (root/"dist/dansheng-android-x86_64-debug.apk")).open("rb") as artifact:
            if client!=hashlib.file_digest(artifact,"sha256").hexdigest():raise RuntimeError("Device is not running the packaged client")
    expected_nonce=secrets.token_hex(16)
    package="org.dansheng.app.test/org.dansheng.app.checks.CampusReadOnlyRunner"
    def phase(name,*extra):
        output=adb("shell","am","instrument","-w","-e","phase",name,*extra,package)
        fields=dict(re.findall(r"^INSTRUMENTATION_RESULT: (\w+)=([A-Za-z0-9_]+)\s*$",output,re.M))
        if fields.get("result") not in ("completed","forgotten"):raise RuntimeError("Instrumentation failed: "+fields.get("reason","no safe reason"))
        return fields
    report={"app_sha256":client,"test_apk_sha256":installed_hash("org.dansheng.app.test"),"api":adb("shell","getprop","ro.build.version.sdk").strip(),"remote_business_writes":0}
    try:
        with socket.socket() as server:
            server.bind(("127.0.0.1",0));server.listen(1);server.settimeout(60)
            port=str(server.getsockname()[1]);route="tcp:"+port
            adb("reverse",route,route)
            try:
                def deliver():
                    with server.accept()[0] as client:
                        client.settimeout(4)
                        if not hmac.compare_digest(client.makefile("rb").readline(64).strip(),expected_nonce.encode()):raise RuntimeError("Invalid pairing")
                        client.sendall(credentials(args.credentials))
                with concurrent.futures.ThreadPoolExecutor(1) as pool:
                    sent=pool.submit(deliver)
                    extra=["-e","only","venue" if args.inspect_venue else "power" if args.inspect_power else "files"] if args.inspect_power or args.inspect_file or args.inspect_venue else []
                    report["first_login"]=phase("seed","-e","nonce",expected_nonce,"-e","port",port,*extra);sent.result()
            finally:adb("reverse","--remove",route)
        if not args.inspect_power and not args.inspect_file:
            if args.ehall_ui:
                import sys
                walk=subprocess.run([sys.executable,str(root/"scripts/verify-ehall-ui.py"),"--adb",args.adb,"--serial",args.serial,"--output",str(root/"dist/preview")],timeout=420)
                report["ehall_ui"]="passed" if walk.returncode==0 else "failed"
            adb("shell","input","keyevent","KEYCODE_WAKEUP");adb("shell","wm","dismiss-keyguard")
            adb("shell","input","keyevent","KEYCODE_HOME");adb("shell","am","force-stop","org.dansheng.app")
            report["after_process_restart"]=phase("restart","-e","venues","yes","-e","foreground","yes" if args.foreground_venue else "no",*extra)
    finally:
        report["logout"]=phase("forget")
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(json.dumps(report,indent=2)+"\n",encoding="utf8")
    print(json.dumps(report))

if __name__=="__main__":run()
