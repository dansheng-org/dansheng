"""Exercise the visible dining 2FA handoff on the offline runner's synthetic profile."""
import argparse,json,re,subprocess,time,xml.etree.ElementTree as ET
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument("--adb",default="adb");p.add_argument("--serial",required=True);p.add_argument("--output",type=Path,required=True);a=p.parse_args()
def adb(*args):return subprocess.run([a.adb,"-s",a.serial,*args],capture_output=True,check=True,timeout=35).stdout
def tree():
    path="/data/local/tmp/ehall-portal.xml"
    if b"dumped to" not in adb("shell","uiautomator","dump",path):return []
    try:return list(ET.fromstring(adb("exec-out","cat",path)).iter("node"))
    except ET.ParseError:return []
def label(n):return (n.get("text","")+" "+n.get("content-desc","")).strip()
def wait(pred,t=45):
    end=time.monotonic()+t
    while time.monotonic()<end:
        for n in tree():
            if pred(n):return n
        time.sleep(.25)
    raise RuntimeError("Expected 2FA screen control not found")
def tap(n):
    l,t,r,b=map(int,re.findall(r"-?\d+",n.get("bounds")));adb("shell","input","tap",str((l+r)//2),str((t+b)//2))
def home():
    adb("shell","input","keyevent","KEYCODE_WAKEUP");adb("shell","wm","dismiss-keyguard");adb("shell","input","keyevent","KEYCODE_HOME")
    adb("shell","am","force-stop","org.dansheng.app");adb("shell","am","start","-W","-f","0x10008000","-n","org.dansheng.app/.MainActivity")
home()
wait(lambda n:"校园办事" in label(n))
for _ in range(5):
    items=[n for n in tree() if "食堂实时客流" in label(n)]
    if items:tap(items[0]);break
    adb("shell","input","swipe","500","1500","500","620","350")
else:raise RuntimeError("Dining card not found")
button=wait(lambda n:"前往验证" in label(n) or "校园双因素认证" in label(n) or "id.fudan.edu.cn" in label(n))
tap(button)
wait(lambda n:n.get('package')=='org.dansheng.app' and label(n)=='完成验证')
tap(wait(lambda n:label(n)=='关闭'))
wait(lambda n:"食堂" in label(n))
home()
wait(lambda n:"校园办事" in label(n))
for _ in range(6):
    entries=[n for n in tree() if "教务公告" in label(n)]
    if entries:tap(entries[0]);break
    adb("shell","input","swipe","500","1500","500","620","350")
else:raise RuntimeError("Notice entry not found")
tap(wait(lambda n:"打开官网公告栏" in label(n)))
end=time.monotonic()+15
while time.monotonic()<end:
    window=adb("shell","dumpsys","window").decode(errors="replace")
    focus=next((r for r in window.splitlines() if 'mCurrentFocus=Window{' in r),'')
    if focus and "MainActivity" not in focus and ('CampusPortalActivity' in focus or 'org.dansheng.app' not in focus):break
    time.sleep(.3)
else:raise RuntimeError("Notice webpage did not open")
result={"verification_window_opened":True,"user_can_return":True,"submitted_otp":False,"notice_webpage_opened":True}
adb("shell","input","keyevent","4");adb("shell","input","keyevent","KEYCODE_HOME")
a.output.write_text(json.dumps(result,indent=2)+"\n",encoding="utf8")
print("Dining verification opened and returned without submitting a verification code.")
