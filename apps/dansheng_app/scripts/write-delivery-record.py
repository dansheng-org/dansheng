"""Bind the campus workbench distribution to the compiled native sources and tested APK."""
import argparse
import hashlib
import json
import shutil
import xml.etree.ElementTree as ET
from pathlib import Path

root=Path(__file__).resolve().parents[1]
dist,local=root/"dist",root/".local"
def load(p):
    return json.loads(p.read_text(encoding="utf-8-sig"))
def sha(p):
    with p.open("rb") as stream:return hashlib.file_digest(stream,"sha256").hexdigest()
def require(ok,reason):
    if not ok:raise SystemExit(reason)

checks={name:sha(dist/name) for name in ("dansheng-android-arm64-beta.apk","dansheng-android-x86_64-debug.apk","official.fudan-sports-0.2.0.dspack")}
release,debug=load(local/"audit-release.json"),load(local/"audit-debug.json")
for proof in (release,debug):
    require(checks[proof["apk"]]==proof["sha256"],"Stale APK audit")
    sig=(local/(Path(proof["apk"]).stem+"-signature.txt")).read_text(encoding="utf-8-sig")
    require("Verified using v2 scheme (APK Signature Scheme v2): true" in sig,"Missing signature verification")
parser=argparse.ArgumentParser()
parser.add_argument("--serial",default="emulator-5592",choices=["emulator-5588","emulator-5590","emulator-5592"])
device=local/"workbench-acceptance"/parser.parse_args().serial
receipt=load(device/"receipt.json")
require(receipt["app_sha256"].lower()==debug["sha256"],"Different client tested")
require(receipt["plugin_sha256"].lower()==checks["official.fudan-sports-0.2.0.dspack"],"Different extension tested")
require(receipt["test_apk_sha256"].lower()==sha(root/"build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk"),"Different instrumented test package")
phases={}
for phase in ("workbench","agentProbe","campusData","sports","coldVenueRestore"):
    rows=dict(x.split(": ",1)[1].split("=",1) for x in (device/(phase+".log")).read_text(encoding="utf-8-sig").splitlines() if x.startswith("INSTRUMENTATION_RESULT: ") and "=" in x)
    require(rows.get("result")=="passed",phase+" did not pass")
    phases[phase]={k:v for k,v in rows.items() if k not in {"pid","step","job_id"}}
require(phases["workbench"].get("confirmed_posts")=="1" and phases["workbench"].get("confirmed_cancel_posts")=="1","Missing manual submissions proof")
require(phases["workbench"].get("mismatch_probe")=="AccountMismatch" and phases["workbench"].get("mismatch_port")=="AuthenticationRequired" and int(phases["workbench"].get("visible_login_user_wait_ms",0))>=55_000,"Missing multi-step foreground sign-in timing proof")
require(phases["workbench"].get("scheduler_shared_auth")=="verified" and phases["workbench"].get("scheduler_write_authority")=="fenced_zero_posts","Missing session boundary proof")
require(phases["sports"].get("launch_posts")=="1","Scheduled simulation missing")
require(phases["coldVenueRestore"].get("cold_venue_posts")=="0" and phases["coldVenueRestore"].get("cold_venue_session")=="authenticated_without_visible_activity","Missing cold WebView fixture result")
jvm=ET.parse(root/"build/app/test-results/testDebugUnitTest/TEST-org.dansheng.app.PortRuntimeTest.xml").getroot()
require(jvm.get("errors")=="0" and jvm.get("failures")=="0","Failed platform suite")
ui=load(root/"dist/preview/result.json")
require(ui.get("tabs")==["eHall","eLearning","Agent","论坛","插件"] and ui.get("native_review") and ui.get("installed_disabled"),"Missing UI receipt")
report={"version":"0.2.2","distribution":checks,"native":load(local/"native/receipt.json"),"android":receipt,"phases":phases,"ui":ui,"jvm_cases":int(jvm.get("tests")),
        "physical_arm64":"not tested","real_campus_mutations":0}
live=load(local/"campus-readonly-release.json")
require(live.get("app_sha256")==debug["sha256"] and live.get("remote_business_writes")==0 and live.get("logout",{}).get("result")=="forgotten","Missing matching real-account Android receipt")
report["real_account_login"]={phase:{k:v for k,v in live[phase].items() if k.endswith("_login")} for phase in ("first_login","after_process_restart")}
report["real_readonly_receipt"]="CAMPUS-READONLY.json"
(dist/"CAMPUS-READONLY.json").write_text(json.dumps(live,indent=2,ensure_ascii=False)+"\n",encoding="utf8")
ehall=load(dist/"preview/ehall-result.json")
portal=load(dist/"preview/portal-result.json")
require(live.get("ehall_ui")=="passed" and all(ehall.get(k) for k in ("card_transactions","power_first_read_second_detail","classroom_periods","shuttle_filters","shuttle_rows","notice_level_toggle")) and portal.get("verification_window_opened") and portal.get("user_can_return") and portal.get("notice_webpage_opened"),"Missing eHall UI receipts")
report["ehall_ui"]=ehall
report["portal_ui"]=portal
(dist/"SHA256SUMS").write_text("".join(f"{value}  {name}\n" for name,value in checks.items()),encoding="ascii")
(dist/"BUILD-INFO.json").write_text(json.dumps(report,indent=2,ensure_ascii=False)+"\n",encoding="utf8")
shutil.copyfile(root/"docs/ehall-0.2.2.md",dist/"VALIDATION.md")
print("Validated distributions, instrumented results, UI journey and native provenance.")
