"""Read-only device journey; screenshots contain only public classroom and shuttle pages."""
import argparse,json,re,subprocess,time,xml.etree.ElementTree as ET
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument("--adb",default="adb");p.add_argument("--serial",required=True);p.add_argument("--output",type=Path,required=True)
a=p.parse_args();a.output.mkdir(exist_ok=True,parents=True)
def adb(*args):return subprocess.run([a.adb,"-s",a.serial,*args],capture_output=True,check=True,timeout=30).stdout
def tree():
    fp="/data/local/tmp/ehall-ui.xml"
    if b"dumped to" not in adb("shell","uiautomator","dump",fp):return ET.Element("empty")
    try:return ET.fromstring(adb("exec-out","cat",fp))
    except ET.ParseError:return ET.Element("empty")
def label(n):return (n.get("text","")+" "+n.get("content-desc","")).strip()
def find(pred,timeout=26):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        for n in tree().iter("node"):
            if pred(label(n),n):return n
        time.sleep(.2)
    raise RuntimeError("Expected eHall control was not visible")
def has(s):return find(lambda t,n:s in t)
def tap(n):
    x,y,r,b=map(int,re.findall(r"-?\d+",n.get("bounds")));adb("shell","input","tap",str((x+r)//2),str((y+b)//2))
def back():adb("shell","input","keyevent","4");time.sleep(.4)
def lookup(s):
    for i in range(5):
        for n in tree().iter("node"):
            if s in label(n):return n
        adb("shell","input","swipe","500","1490","500","650","350")
    raise RuntimeError("Home entry not found: "+s)
def snap(name): (a.output/(name+".png")).write_bytes(adb("exec-out","screencap","-p"))
def home():
    adb("shell","input","keyevent","KEYCODE_WAKEUP");adb("shell","wm","dismiss-keyguard")
    adb("shell","input","keyevent","KEYCODE_HOME");adb("shell","am","force-stop","org.dansheng.app")
    adb("shell","am","start","-W","-f","0x10008000","-n","org.dansheng.app/.MainActivity");has("校园办事")
results={};print("eHall: starting card transactions",flush=True)
home();tap(find(lambda t,n:'查看明细' in t or '查看消费明细' in t or ('校园卡' in t and '¥' in t)))
has("校园卡明细");results["card_transactions"]=True
print("eHall: checking electricity taps",flush=True);home();power=lookup("寝室电量");tap(power)
find(lambda t,n:'kWh'.lower() in t.lower() and ('寝室电量' in t or any(ch.isdigit() for ch in t)),40)
has("校园办事");tap(lookup("寝室电量"));has("用电历史");results["power_first_read_second_detail"]=True
print("eHall: checking classroom taps",flush=True);home();tap(lookup("教室空位"));has("间教室");has("校园办事");tap(lookup("教室空位"));has("枫林");has("空闲");find(lambda t,n:"第1节" in t or "第1节" in n.get("content-desc",""),45)
snap("ehall-classrooms");results["classroom_periods"]=True
print("eHall: checking shuttle",flush=True);home();tap(lookup("校车班次"));has("始发站");has("终点站");has("工作日")
tap(has("工作日"));toggle=has("点击以显示全部");tap(toggle)
find(lambda t,n:bool(re.fullmatch(r'\d{1,2}:\d{2}',t)) or bool(re.search(r'邯郸.*\d{1,2}:\d{2}',t,re.S)),35)
snap("ehall-shuttle")
if any("休息日" in label(n) for n in tree().iter("node")):tap(has("休息日"))
else:tap(has("节假日"))
has("始发站");results["shuttle_filters"]=True;results["shuttle_rows"]=True
print("eHall: checking notices",flush=True);home();tap(lookup("教务公告"));has("本科生");tap(has("研究生"));find(lambda t,n:"研究生" in t and n.get("selected")=="true");results["notice_level_toggle"]=True
(a.output/"ehall-result.json").write_text(json.dumps(results,indent=2)+"\n",encoding="utf8")
print("Verified eHall navigation, real metric, period grid, shuttle controls and notice level toggle.")
