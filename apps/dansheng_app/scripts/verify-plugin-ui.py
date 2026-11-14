"""Drive the Android document picker and optional plugin on a dedicated QA emulator.
This workflow never opens the login, booking, or cancellation actions.
"""
import argparse, hashlib, json, re, subprocess, time, xml.etree.ElementTree as ET
from pathlib import Path

parser=argparse.ArgumentParser()
parser.add_argument("package",type=Path)
parser.add_argument("--serial",required=True)
parser.add_argument("--adb",default="adb")
parser.add_argument("--output",type=Path,required=True)
parser.add_argument("--sandbox-only",action="store_true",help="exercise local install without approving the platform policy")
parser.add_argument("--continue-confirmation",action="store_true",help="continue the same import at its observed native enable prompt")
args=parser.parse_args()
if not args.serial.startswith("emulator-"):
    raise SystemExit("QA emulator required")
args.output.mkdir(parents=True,exist_ok=True)
index=0
def adb(*v):
    r=subprocess.run([args.adb,"-s",args.serial,*map(str,v)],capture_output=True,timeout=40)
    if r.returncode: raise RuntimeError(r.stderr.decode(errors="replace")[:300])
    return r.stdout
def dump():
    global index
    index+=1
    path="/data/local/tmp/dansheng-test-window.xml"
    # Avoid reading the previous hierarchy when Android reports a null root.
    text=adb("shell","uiautomator","dump",path).decode(errors="replace")
    if "dumped to" not in text:return ET.Element("empty")
    raw=adb("exec-out","cat",path)
    root=ET.fromstring(raw)
    (args.output/f"{index:03d}.xml").write_bytes(raw)
    return root
def label(node):
    return (node.get("text","")+" "+node.get("content-desc","")).strip()
def wait(predicate,seconds=45,scroll=False):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        root=dump()
        for node in root.iter("node"):
            if predicate(node):
                return node
        if scroll and root.tag!="empty": adb("shell","input","swipe",520,1800,520,750,450)
        time.sleep(.4)
    raise RuntimeError("required UI state not observed")
def eq(value):return lambda n:label(n)==value
def scroll(root):
    region=next((n for n in root.iter("node") if n.get("scrollable")=="true" and n.get("package")=="org.dansheng.app"),None)
    if region is None:return
    l,t,r,b=map(int,re.findall(r"-?\d+",region.get("bounds")))
    adb("shell","input","swipe",(l+r)//2,t+3*(b-t)//4,(l+r)//2,t+(b-t)//4,420)
def tap(node):
    l,t,r,b=map(int,re.findall(r"-?\d+",node.attrib["bounds"]))
    if r<=l or b<=t: raise RuntimeError("node is offscreen")
    if node.get("class")=="android.widget.Switch" and r-l>350:
        # Flutter can merge the switch and header semantics into the card.
        adb("shell","input","tap",r-160,t+110)
    else: adb("shell","input","tap",(l+r)//2,(t+b)//2)
def taplabel(s):tap(wait(eq(s)))
def sports_card(n):
    return "ID: official.fudan-sports" in label(n)
def control(root,kind):
    for card in root.iter("node"):
        if sports_card(card):
            for node in card.iter("node"):
                if kind(node):return node
    return None
def on_card(kind):
    for i in range(8):
        root=dump()
        n=next((n for n in root.iter("node") if kind(n) and "official.fudan-sports" in label(n)),None)
        if n is None:n=control(root,kind)
        if n is not None:return n
        scroll(root)
    raise RuntimeError("plugin control not found")
def checkpoint(s):print(s,flush=True)
digest=hashlib.sha256(args.package.read_bytes()).hexdigest()
switch=lambda n:n.get("class")=="android.widget.Switch"
if args.continue_confirmation:
    wait(lambda n:label(n)=="启用插件并授权")
    taplabel("确认")
else:
    adb("push",args.package,"/sdcard/Download/"+args.package.name)
    root=dump()
    if not any(n.get("package","").endswith("documentsui") for n in root.iter("node")):
        adb("shell","am","start","-n","org.dansheng.app/.MainActivity")
        taplabel("导入插件包 (.dspack)")
    current=wait(lambda n:n.get("package","").endswith("documentsui"))
    root=dump()
    if not any(eq(args.package.name)(n) for n in root.iter("node")):
        tap(wait(lambda n:label(n) in ("Show roots","显示根目录","打开导航菜单")))
        wait(lambda n:label(n) in ("Open from","打开文件","打开位置"))
        options=[n for n in dump().iter("node") if label(n) in ("Downloads","下载")]
        if not options: raise RuntimeError("Downloads drawer root missing")
        tap(options[-1])
    tap(wait(eq(args.package.name)))
    taplabel("确认")
    if args.sandbox_only:
        taplabel("仅安装普通插件")
    else:
        entry=wait(lambda n:n.get("class")=="android.widget.EditText" and n.get("package")=="org.dansheng.app")
        tap(entry); adb("shell","input","text",digest)
        wait(lambda n:n.get("class")=="android.widget.EditText" and n.get("text","").lower()==digest,60)
        taplabel("验证")
    off=on_card(switch)
    assert off.get("checked")=="false"
    checkpoint("imported disabled")
    tap(off)
    # A touch can stop a still-decelerating catalog. Reinspect the same switch
    # before another local tap; never drive a plugin action in this check.
    for attempt in range(3):
        time.sleep(.7); page=dump()
        yes=next((n for n in page.iter("node") if eq("确认")(n)),None)
        if yes is not None: tap(yes);break
        still_off=on_card(switch)
        if still_off.get("checked")=="true":break
        tap(still_off)
    else: raise RuntimeError("enable confirmation not observed")
on=on_card(switch); assert on.get("checked")=="true"
checkpoint("enabled")
tap(on)
off=on_card(switch); assert off.get("checked")=="false"
checkpoint("disabled")
tap(on_card(lambda n:label(n)=="卸载插件")); taplabel("卸载"); taplabel("确认")
time.sleep(.8)
removed=dump()
assert all(not sports_card(n) for n in removed.iter("node"))
checkpoint("uninstalled")
(args.output/"result.json").write_text(json.dumps({"package_sha256":digest,"states":["imported_disabled","enabled","disabled","uninstalled"]},indent=2))
