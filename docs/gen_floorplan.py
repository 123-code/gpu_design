#!/usr/bin/env python3
"""Generate an honest device-utilization 'floorplan' SVG for tiny-gpu on the
GW2AR-18 (Tang Nano 20K), straight from the P&R report numbers.

NOTE: This is a *utilization map*, not exact tile placement. Gowin's real
per-cell XY coordinates live in the proprietary impl/pnr/tiny_gpu.db and are
only viewable in the GUI Floorplanner. Everything drawn here is backed by
impl/pnr/tiny_gpu.rpt.txt; the I/O pin numbers are the real ones from gpu.cst.
"""

# --- real numbers from impl/pnr/tiny_gpu.rpt.txt ---
CLS_USED, CLS_TOT   = 2300, 10368     # configurable logic slices (the fabric)
FF_USED,  FF_TOT    = 1692, 15552
LUT_USED            = 2039
ALU_USED            = 940
BSRAM_USED, BSRAM_TOT = 10, 46        # 8 SDPB + 2 pROM
DSP_USED,  DSP_TOT  = 12, 24          # 8 MULT9x9 + 10 MULTADD18x18
# real physical pin placement (gpu.cst): name -> pin number, edge
PINS = [
    ("clk",        4,  "L"),
    ("led[0]",     15, "B"), ("led[1]", 16, "B"), ("led[2]", 17, "B"),
    ("led[3]",     18, "B"), ("led[4]", 19, "B"), ("led[5]", 20, "B"),
    ("uart_tx",    69, "R"), ("uart_rx", 70, "R"),
]

W, H = 1100, 760
M = 70                       # die margin (I/O ring sits here)
die = (M, M, W-2*M, H-2*M)

def rect(x,y,w,h,fill,stroke="#333",sw=1,rx=0,op=1.0):
    return (f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" '
            f'rx="{rx}" fill="{fill}" fill-opacity="{op}" stroke="{stroke}" stroke-width="{sw}"/>')

def text(x,y,s,size=15,fill="#111",anchor="start",weight="normal",ff="monospace"):
    return (f'<text x="{x:.1f}" y="{y:.1f}" font-family="{ff}" font-size="{size}" '
            f'font-weight="{weight}" fill="{fill}" text-anchor="{anchor}">{s}</text>')

svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
       f'viewBox="0 0 {W} {H}" font-family="monospace">']
svg.append(rect(0,0,W,H,"#f7f8fa",stroke="none"))
svg.append(text(M, 40, "tiny-gpu  —  GW2AR-18 (Tang Nano 20K) device utilization map",
                22, "#111", weight="bold"))
svg.append(text(M, 60, "proportional to real P&amp;R usage · I/O pin numbers are physical (gpu.cst)",
                13, "#667"))

dx,dy,dw,dh = die
svg.append(rect(dx,dy,dw,dh,"#ffffff","#222",2,8))   # the die

# ---- columns inside the die ----
# left ~62%: logic fabric (CLS) ; mid: BSRAM column ; right: DSP column
pad = 24
fab_x = dx+pad; fab_y=dy+pad
fab_w = dw*0.58; fab_h = dh-2*pad
svg.append(rect(fab_x, fab_y, fab_w, fab_h, "#eef3fb", "#9bb3d4", 1.5, 4))
svg.append(text(fab_x+10, fab_y+22, "LOGIC FABRIC (CLS)", 14, "#2b4a7a", weight="bold"))

# draw CLS as a grid, fill the used fraction
cols, rows = 36, 22
gx0, gy0 = fab_x+12, fab_y+34
gw = (fab_w-24)/cols; gh=(fab_h-46)/rows
frac = CLS_USED/CLS_TOT
nfill = round(frac*cols*rows)
i=0
for r in range(rows):
    for c in range(cols):
        used = i < nfill
        i+=1
        svg.append(rect(gx0+c*gw, gy0+r*gh, gw-1.2, gh-1.2,
                        "#3b6fb5" if used else "#dde6f2", "none"))
svg.append(text(fab_x+10, fab_y+fab_h-10,
                f"CLS {CLS_USED}/{CLS_TOT} ({100*frac:.0f}%)  ·  {LUT_USED} LUT + {ALU_USED} ALU  ·  {FF_USED} FF",
                13, "#2b4a7a"))

# BSRAM column
bx = fab_x+fab_w+pad; by=fab_y; bw=dw*0.14; bh=fab_h
svg.append(rect(bx,by,bw,bh,"#fff3e6","#e0a766",1.5,4))
svg.append(text(bx+bw/2, by+22, "BSRAM", 14, "#9a5b12", anchor="middle", weight="bold"))
nb=BSRAM_TOT; cellh=(bh-40)/nb
for k in range(nb):
    used = k < BSRAM_USED
    svg.append(rect(bx+10, by+30+k*cellh, bw-20, cellh-3,
                    "#e8902b" if used else "#f3e2cb", "none"))
svg.append(text(bx+bw/2, by+bh-8, f"{BSRAM_USED}/{BSRAM_TOT}", 12, "#9a5b12", anchor="middle"))

# DSP column
ex = bx+bw+pad; ey=fab_y; ew=dw*0.14; eh=fab_h
svg.append(rect(ex,ey,ew,eh,"#e9f7ee","#5cae7b",1.5,4))
svg.append(text(ex+ew/2, ey+22, "DSP", 14, "#1f6b3d", anchor="middle", weight="bold"))
nd=DSP_TOT; cellhd=(eh-40)/nd
for k in range(nd):
    used = k < DSP_USED
    svg.append(rect(ex+10, ey+30+k*cellhd, ew-20, cellhd-3,
                    "#2e9e5b" if used else "#cfecd9", "none"))
svg.append(text(ex+ew/2, ey+eh-8, f"{DSP_USED}/{DSP_TOT} (50%)", 12, "#1f6b3d", anchor="middle"))
svg.append(text(ex+ew/2, ey+eh+18, "MAC arrays", 11, "#1f6b3d", anchor="middle"))

# ---- I/O ring: place real pins on the perimeter ----
def pin_marker(px,py,label,num,anchor):
    s=[rect(px-6,py-6,12,12,"#444","#000",1,2)]
    s.append(text(px + (14 if anchor=='start' else -14 if anchor=='end' else 0),
                  py+ (0 if anchor in ('start','end') else -10),
                  f"{label}:{num}", 12, "#111", anchor))
    return "".join(s)

# left edge: clk ; bottom: leds ; right: uart
left  = [p for p in PINS if p[2]=="L"]
bot   = [p for p in PINS if p[2]=="B"]
right = [p for p in PINS if p[2]=="R"]
for j,(nm,num,_) in enumerate(left):
    py = dy + dh*0.5
    svg.append(pin_marker(dx-30, py, nm, num, "end"))
for j,(nm,num,_) in enumerate(bot):
    px = dx + dw*(0.30 + 0.40*j/max(1,len(bot)-1))
    svg.append(pin_marker(px, dy+dh+30, nm, num, "middle"))
for j,(nm,num,_) in enumerate(right):
    py = dy + dh*(0.4+0.18*j)
    svg.append(pin_marker(dx+dw+30, py, nm, num, "start"))

svg.append(text(M, H-14,
    "Exact per-cell placement is in impl/pnr/tiny_gpu.db (Gowin GUI Floorplanner only). "
    "This map is utilization-proportional.", 12, "#889"))
svg.append("</svg>")
open("docs/floorplan.svg","w").write("\n".join(svg))
print("wrote docs/floorplan.svg")
