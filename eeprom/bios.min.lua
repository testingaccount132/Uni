local V="UniOS BIOS 1.1"local B="/boot/init.lua"local g,W,H,r=nil,80,25,3
do local a,s for a in component.list("gpu")do g=component.proxy(a)break end
for a in component.list("screen")do s=component.proxy(a)break end
if g and s then g.bind(s.address)W,H=g.maxResolution()g.setResolution(W,H)
g.setBackground(0x050D18)g.setForeground(0xBBCCDD)g.fill(1,1,W,H," ")
g.setBackground(0x0D1E30)g.setForeground(0x00B4FF)g.fill(1,1,W,1," ")
g.set(2,1,V)g.setForeground(0x4A6070)g.set(W-9,1,"BIOS boot")
g.setBackground(0x050D18)end end
local function p(m,c)if not g then return end if c then g.setForeground(c)end
if r>H-1 then g.copy(1,2,W,H-2,0,-1)g.setBackground(0x050D18)
g.fill(1,H-1,W,1," ")r=H-1 end g.setBackground(0x050D18)
g.set(2,r,tostring(m))g.setForeground(0xBBCCDD)r=r+1 end
_G._println=p
local function halt(m)if g then g.setBackground(0xAA0000)g.setForeground(0xFFFFFF)
g.fill(1,1,W,H," ")g.set(2,2,"[ BIOS PANIC ]")g.setBackground(0x050D18)
g.setForeground(0xFF5555)local y=4
for l in(tostring(m).."\n"):gmatch("([^\n]*)\n")do g.set(2,y,l:sub(1,W-2))
y=y+1 if y>H-2 then break end end g.setForeground(0x4A6070)
g.set(2,H-1,"System halted. Reboot to recover.")end
while true do computer.pullSignal(1)end end
p("Scanning...",0x4A6070)local bf,ba
for a in component.list("filesystem")do local f=component.proxy(a)
if f.exists(B)then bf=f ba=a break end end
if not bf then for a in component.list("filesystem")do local f=component.proxy(a)
if not f.isReadOnly()then bf=f ba=a break end end end
if not bf then halt("No bootable filesystem.\nInsert UniOS disk and reboot.")end
p("Boot: "..ba:sub(1,8).."...",0x4A6070)
if not bf.exists(B)then
p("",0xFF5555)p("RECOVERY MODE",0xFF5555)
p("Missing: "..B,0xFFAA00)
local inet for a in component.list("internet")do inet=component.proxy(a)break end
if not inet then halt("No internet card.\nInstall internet card to recover.")end
p("Internet found.",0x00CC66)p("[1] Bootstrap installer",0x00B4FF)
p("[2] Reboot",0x4A6070)p("[3] Halt",0x4A6070)
while true do local e,_,c=computer.pullSignal(0.5)
if e=="key_down"then if c==49 then p("Downloading...",0x00B4FF)
local u="https://raw.githubusercontent.com/testingaccount132/Uni/main/tools/bootstrap.lua"
local q,re=inet.request(u)if not q then halt("Download failed: "..tostring(re))end
local dl=computer.uptime()+30
while computer.uptime()<dl do local ok,er=q.finishConnect()
if ok then break end if ok==nil then halt("Connect failed")end
computer.pullSignal(0.1)end
local ch={}while computer.uptime()<dl do local d,e=q.read(65536)
if d then ch[#ch+1]=d elseif e then break else if#ch>0 then break end
computer.pullSignal(0.1)end end q.close()
local s=table.concat(ch)if#s<50 then halt("Download too small")end
p("OK ("..#s.."B)",0x00CC66)
local fn,pe=load(s,"=bootstrap","t",_G)
if not fn then halt("Parse: "..tostring(pe))end
pcall(fn)p("Done. Press key to reboot.",0xBBCCDD)
computer.pullSignal()computer.shutdown(true)return
elseif c==50 then computer.shutdown(true)return
elseif c==51 then while true do computer.pullSignal(1)end
end end end end
local h,e=bf.open(B,"r")if not h then halt("Cannot open "..B..": "..tostring(e))end
local ch={}repeat local c=bf.read(h,math.huge)if c then ch[#ch+1]=c end until not c
bf.close(h)local src=table.concat(ch)
p(string.format("Loaded %s (%dB)",B,#src),0x4A6070)
local tf,se=load(src,"=init","t")
if not tf then halt("Syntax error:\n"..tostring(se))end
p("Booting...",0x00B4FF)
local env=setmetatable({},{__index=_G})
env.boot_fs=bf env.boot_addr=ba env._BIOS_VERSION=V
env._UNI_VERSION="UniOS 1.0"env._root_fs=bf env._root_addr=ba
local fn=load(src,"=init","t",env)
local ok,re=xpcall(fn,function(e)return debug and debug.traceback(e,2)or tostring(e)end)
if not ok then halt("init crashed:\n"..tostring(re))end
