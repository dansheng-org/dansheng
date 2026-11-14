"""Exercise the actual five-tab UI and native file-import review on a dedicated emulator.
No campus write, browser login, or timer is triggered by this workflow.
"""
import argparse, json, re, subprocess, time
from pathlib import Path
import xml.etree.ElementTree as ET

p=argparse.ArgumentParser()
p.add_argument("--serial",default="emulator-5592")
p.add_argument("--adb",default="adb")
p.add_argument("--output",type=Path,required=True)
p.add_argument("--package",type=Path,required=True)
a=p.parse_args(); a.output.mkdir(parents=True,exist_ok=True)
def adb(*v):
    cmd=subprocess.run([a.adb,"-s",a.serial,*map(str,v)],capture_output=True,timeout=35)
    if cmd.returncode: raise RuntimeError(cmd.stderr.decode(errors="replace")[:220])
    return cmd.stdout
def tree():
    f="/data/local/tmp/workbench-qa.xml"
    r=adb("shell","uiautomator","dump",f)
    if b"dumped to" not in r:return ET.Element("empty")
    return ET.fromstring(adb("exec-out","cat",f))
def label(n):return (n.get("text","")+" "+n.get("content-desc","")).strip()
def wait(pred,timeout=45):
    until=time.monotonic()+timeout
    while time.monotonic()<until:
        for n in tree().iter("node"):
            if pred(n):return n
        time.sleep(.25)
    raise RuntimeError("Visible control not found: "+repr(pred))
def tap(n):
    l,t,r,b=map(int,re.findall(r"-?[0-9]+",n.get("bounds")))
    adb("shell","input","tap",(l+r)//2,(t+b)//2)
def click(s):tap(wait(lambda n:label(n)==s))
def tab(s):tap(wait(lambda n:label(n).startswith(s+"\n") and "标签" in label(n)))
def capture(name):
    (a.output/(name+".png")).write_bytes(adb("exec-out","screencap","-p"))
    local=Path(__file__).resolve().parents[1]/".local"/"workbench-ui-state"
    local.mkdir(parents=True,exist_ok=True)
    (local/(name+".xml")).write_bytes(ET.tostring(tree(),encoding="utf8"))
def note(s):print(s,flush=True)

name=adb("emu","avd","name").decode().splitlines()[0].strip()
assert name in ("dansheng-app-api36","dansheng-app-api28","dansheng-core-api36")
adb("push",a.package,"/sdcard/Download/"+a.package.name)
adb("shell","input","keyevent","KEYCODE_WAKEUP"); adb("shell","wm","dismiss-keyguard")
adb("shell","input","keyevent","KEYCODE_HOME");adb("shell","am","force-stop","org.dansheng.app")
adb("shell","am","start","-W","-f","0x10008000","-n","org.dansheng.app/.MainActivity")
wait(lambda n:label(n)=="校园办事");capture("01-ehall");note("eHall first")
for title,heading,name in (("eLearning","课程学习","02-elearning"),("Agent","校园助手","03-agent"),("论坛","复旦树洞","04-forum"),("插件","插件","05-plugins")):
    tab(title);wait(lambda n:label(n)==heading)
    if title=="插件":wait(lambda n:"未安装插件" in label(n))
    capture(name);note("opened "+title)
click("导入插件包 (.dspack)");wait(lambda n:label(n)=="浏览并导入");capture("06-import")
click("浏览并导入")
wait(lambda n:n.get("package","").endswith("documentsui"))
if not any(label(n)==a.package.name for n in tree().iter("node")):
    tap(wait(lambda n:label(n) in ("Show roots","显示根目录","打开导航菜单")))
    wait(lambda n:label(n) in ("Open from","打开文件","打开位置"))
    downloads=[n for n in tree().iter("node") if label(n) in ("Downloads","下载")]
    tap(downloads[-1])
click(a.package.name)
install=wait(lambda n:n.get("package")=="org.dansheng.app" and n.get("clickable")=="true" and
             n.get("class","").endswith("Button") and "安装" in label(n))
wait(lambda n:"已核验发布版本" in label(n))
capture("07-native-review");note("native review visible")
tap(install)
wait(lambda n:label(n).startswith("定时抢场") and "已停用" in label(n))
capture("08-disabled")
(a.output/"result.json").write_text(json.dumps({"tabs":["eHall","eLearning","Agent","论坛","插件"],
     "native_review":True,"installed_disabled":True},ensure_ascii=False,indent=2),encoding="utf8")
