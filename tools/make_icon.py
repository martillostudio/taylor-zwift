# Genera el icono de «Taylor Mandos»: piñón con flechas de subir/bajar marcha.
import math, json, os
from PIL import Image, ImageDraw, ImageFilter

S = 4096  # supersampling

def lerp(a, b, t): return tuple(int(a[i] + (b[i]-a[i])*t) for i in range(3))

def gradient(size, c1, c2):
    g = Image.new("RGB", (size, size))
    px = g.load()
    for y in range(size):
        for x in range(size):
            pass
    # diagonal gradient via two 1D images (fast)
    lin = Image.linear_gradient("L").resize((size, size))
    lin = lin.rotate(45, resample=Image.BICUBIC, expand=False)
    a = Image.new("RGB", (size, size), c1); b = Image.new("RGB", (size, size), c2)
    return Image.composite(b, a, lin)

def cog_polygon(cx, cy, r_base, r_tip, teeth):
    pts = []
    pitch = 2*math.pi/teeth
    for i in range(teeth):
        a0 = i*pitch - math.pi/2
        base_half = pitch*0.30
        tip_half = pitch*0.20
        mid = a0 + pitch/2
        # valley arc before tooth
        for k in range(4):
            a = a0 + (mid - base_half - a0)*k/3
            pts.append((cx + r_base*math.cos(a), cy + r_base*math.sin(a)))
        pts.append((cx + r_tip*math.cos(mid - tip_half), cy + r_tip*math.sin(mid - tip_half)))
        pts.append((cx + r_tip*math.cos(mid + tip_half), cy + r_tip*math.sin(mid + tip_half)))
        for k in range(4):
            a = mid + base_half + (a0 + pitch - mid - base_half)*k/3
            pts.append((cx + r_base*math.cos(a), cy + r_base*math.sin(a)))
    return pts

def glyph(size, scale):
    """Capa RGBA con el piñón y las flechas, centrada; scale = fracción del lienzo."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    c = size/2
    R = size*scale/2
    r_tip, r_base, r_hole = R, R*0.84, R*0.60
    white = (255, 255, 255, 255)
    d.polygon(cog_polygon(c, c, r_base, r_tip, 18), fill=white)
    # agujero del piñón (transparente)
    hole = Image.new("L", (size, size), 0)
    ImageDraw.Draw(hole).ellipse([c-r_hole, c-r_hole, c+r_hole, c+r_hole], fill=255)
    img.putalpha(Image.composite(Image.new("L", (size, size), 0), img.getchannel("A"), hole))
    d = ImageDraw.Draw(img)
    # flechas: subir (ámbar) y bajar (blanca)
    w, h, gap = r_hole*0.95, r_hole*0.40, r_hole*0.14
    amber = (255, 176, 32, 255)
    up = [(c - w/2, c - gap), (c, c - gap - h), (c + w/2, c - gap)]
    dn = [(c - w/2, c + gap), (c, c + gap + h), (c + w/2, c + gap)]
    d.polygon(up, fill=amber)
    d.polygon(dn, fill=white)
    return img

def shadow_of(layer, radius, offset, opacity):
    a = layer.getchannel("A").point(lambda v: v*opacity)
    sh = Image.new("RGBA", layer.size, (0, 0, 0, 0))
    sh.putalpha(a)
    sh = sh.filter(ImageFilter.GaussianBlur(radius))
    out = Image.new("RGBA", layer.size, (0, 0, 0, 0))
    out.paste(sh, (0, offset), sh)
    return out

C1, C2 = (22, 27, 84), (24, 140, 220)   # índigo → azul eléctrico

# iOS: cuadrado a sangre (el sistema redondea las esquinas)
bg = gradient(S, C1, C2).convert("RGBA")
g = glyph(S, 0.70)
ios = Image.alpha_composite(bg, shadow_of(g, S*0.012, int(S*0.012), 0.35))
ios = Image.alpha_composite(ios, g).convert("RGB").resize((1024, 1024), Image.LANCZOS)
pass

# macOS: «squircle» con margen y sombra, según la plantilla de Apple (824/1024, radio ~185)
mac = Image.new("RGBA", (S, S), (0, 0, 0, 0))
m = S*100/1024; rad = S*185/1024
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([m, m, S-m, S-m], radius=rad, fill=255)
tile = gradient(S, C1, C2).convert("RGBA"); tile.putalpha(mask)
mac = Image.alpha_composite(mac, shadow_of(tile, S*0.012, int(S*0.010), 0.45))
mac = Image.alpha_composite(mac, tile)
g = glyph(S, 0.56)
mac = Image.alpha_composite(mac, shadow_of(g, S*0.010, int(S*0.010), 0.35))
mac = Image.alpha_composite(mac, g)

# Uso: python3 tools/make_icon.py  (desde la raíz del repo; necesita Pillow)
out = "App/BridgeSources/Assets.xcassets/AppIcon.appiconset"
os.makedirs(out, exist_ok=True)
ios.save(f"{out}/ios-1024.png")
images = [{"filename": "ios-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}]
for pt in (16, 32, 128, 256, 512):
    for sc in (1, 2):
        px = pt*sc
        name = f"mac-{pt}@{sc}x.png"
        mac.resize((px, px), Image.LANCZOS).save(f"{out}/{name}")
        images.append({"filename": name, "idiom": "mac", "scale": f"{sc}x", "size": f"{pt}x{pt}"})
json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, open(f"{out}/Contents.json", "w"), indent=2)
pass
print("ok")
