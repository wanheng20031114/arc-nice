"""Author Mirage's editable native Godot scene. No runtime geometry generation.

All painting comes from ImageGen atlases. PIL only cuts/alines native RGBA regions;
no RGB-to-alpha keying, image synthesis, or image resampling is performed.
Layout coordinates were hand traced against Total CS' Mirage callout reference,
then adapted to 32 px movement cells, with an offset underpass for a flat 2D map.
"""
from pathlib import Path
import base64
import json
import math
import struct
from collections import deque
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'scene/pvp/maps'
ART = ROOT / 'resources/texture/pvp'
OUT.mkdir(parents=True, exist_ok=True)
ART.mkdir(parents=True, exist_ok=True)
S = 32
W, H = 60, 50
SX, SY = 2.4, 2.2

# Unequal source regions are deliberately measured, not assumed to be a grid.
PROPS = {
    'arch': (0, 0, 384, 395), 'crates': (419, 0, 767, 380),
    'van': (814, 0, 1086, 400), 'palm': (1120, 0, 1536, 397),
    'market_stall': (0, 391, 390, 728), 'column': (429, 393, 742, 719),
    'ammo_crates': (806, 409, 1107, 717), 'pottery': (1140, 392, 1536, 724),
    'ak47': (0, 758, 446, 962), 'desert_eagle': (465, 754, 762, 965),
    'rugs': (779, 727, 1128, 1024), 'bench': (1159, 755, 1536, 977),
}
props_image = Image.open(ART / 'mirage_props.png')
assert props_image.mode == 'RGBA' and props_image.getchannel('A').getextrema()[0] == 0
for name, bounds in PROPS.items():
    part = props_image.crop(bounds)
    alpha_bounds = part.getchannel('A').getbbox()
    x, y, _, _ = bounds
    a, b, c, d = alpha_bounds
    if name == 'arch':
        part.crop(alpha_bounds).save(ART / 'mirage_icon.png')
    region = (x+a, y+b, c-a, d-b)
    (ART / f'{name}.tres').write_text(
        '[gd_resource type="AtlasTexture" load_steps=2 format=3]\n\n'
        '[ext_resource type="Texture2D" path="res://resources/texture/pvp/mirage_props.png" id="1"]\n\n'
        '[resource]\natlas = ExtResource("1")\n'
        f'region = Rect2({region[0]}, {region[1]}, {region[2]}, {region[3]})\n', encoding='utf8')

# Lossless crop + grid packing only. The TileMapLayer scales 313 source px to 32
# world px using Godot's texture filtering; source art is preserved in full.
surfaces = Image.open(ART / 'mirage_surfaces.png')
edges = [0, 313, 627, 941]
packed = Image.new('RGB', (1252, 1252))
for j in range(4):
    for i in range(4):
        packed.paste(surfaces.crop((edges[i], edges[j], edges[i]+313, edges[j]+313)), (i*313, j*313))
packed.save(ART / 'mirage_tiles.png')
tileset = ['[gd_resource type="TileSet" load_steps=3 format=3]', '',
    '[ext_resource type="Texture2D" path="res://resources/texture/pvp/mirage_tiles.png" id="1"]', '',
    '[sub_resource type="TileSetAtlasSource" id="Atlas"]',
    'texture = ExtResource("1")', 'texture_region_size = Vector2i(313, 313)']
for j in range(4):
    for i in range(4):
        tileset.append(f'{i}:{j}/0 = 0')
tileset += ['', '[resource]', 'tile_size = Vector2i(313, 313)', 'sources/0 = SubResource("Atlas")']
(ART/'mirage_tileset.tres').write_text('\n'.join(tileset)+'\n', encoding='utf8')

# Hand-authored connected areas. Coordinates correspond to the reference radar.
AREAS = [
    ('B Site', 0, [(80,174),(207,174),(230,198),(348,198),(348,253),(284,253),(284,287),(233,287),(233,319),(147,319),(80,285)]),
    ('B Apartments', 8, [(120,132),(320,132),(320,169),(213,169),(213,205),(170,205),(170,164),(120,164)]),
    ('Back Alley', 2, [(300,145),(449,145),(449,196),(320,196),(320,175),(300,175)]),
    ('House', 9, [(430,126),(596,126),(596,165),(484,165),(484,192),(430,192)]),
    ('T Alley', 2, [(570,146),(683,146),(724,183),(724,271),(679,271),(679,203),(570,203)]),
    ('T Spawn', 3, [(671,252),(726,252),(726,449),(701,475),(650,475),(650,431),(674,415)]),
    ('Side Alley', 0, [(524,202),(572,202),(572,321),(592,321),(592,391),(538,391),(538,285),(524,271)]),
    ('Top Mid', 0, [(540,296),(589,321),(589,412),(480,412),(480,343),(540,343)]),
    ('Mid', 0, [(350,348),(540,348),(540,412),(430,412),(430,435),(350,435)]),
    ('Catwalk', 0, [(343,253),(374,253),(401,318),(548,318),(548,352),(371,352),(343,301)]),
    ('B Short', 0, [(300,224),(352,224),(375,273),(347,294),(317,255),(300,255)]),
    ('Ladder Room', 9, [(284,269),(327,269),(327,337),(284,337)]),
    ('Window', 9, [(239,337),(352,337),(352,377),(308,377),(308,415),(238,415)]),
    ('Underpass', 8, [(390,185),(430,185),(430,220),(332,220),(332,414),(363,414),(363,441),(309,441),(309,199),(390,199)]),
    ('Market', 11, [(133,305),(235,305),(235,381),(133,381)]),
    ('CT Passage', 11, [(233,365),(276,365),(276,538),(234,538)]),
    ('Jungle', 0, [(269,442),(309,442),(309,465),(391,465),(391,509),(302,509),(269,487)]),
    ('Connector', 15, [(372,405),(414,405),(414,485),(372,485)]),
    ('A Site', 3, [(378,484),(428,484),(450,502),(548,502),(548,544),(506,544),(506,617),(463,659),(398,677),(331,658),(333,616),(377,598)]),
    ('CT Spawn', 11, [(233,515),(278,515),(278,590),(333,620),(364,620),(364,665),(315,665),(252,639),(231,605),(188,582),(188,552),(233,552)]),
    ('A Ramp', 0, [(540,490),(629,490),(629,443),(681,443),(681,491),(650,491),(650,535),(540,535)]),
    ('Palace Entrance', 10, [(651,465),(694,465),(694,519),(664,519),(664,614),(621,614),(621,490),(651,490)]),
    ('Palace', 10, [(547,574),(626,574),(626,594),(674,594),(674,638),(541,638),(541,611),(509,611),(509,568),(547,568)]),
]

def point_in_polygon(x, y, polygon):
    inside = False
    for i, (x1,y1) in enumerate(polygon):
        x2,y2 = polygon[(i+1)%len(polygon)]
        if (y1>y)!=(y2>y) and x < (x2-x1)*(y-y1)/(y2-y1)+x1:
            inside = not inside
    return inside

floor = {}
for label, material, polygon in AREAS:
    for y in range(H):
        for x in range(W):
            if point_in_polygon((x+.5)*S/SX, (y+.5)*S/SY, polygon):
                floor[x,y] = material

# Preserve the narrow, offset passage and make the two-level underpass navigable
# in a single 2D plane. Thin walkways never depend on a single raster sample.
def fill_ref_rect(x1,y1,x2,y2,material=0):
    for y in range(math.floor(y1*SY/S),math.ceil(y2*SY/S)):
        for x in range(math.floor(x1*SX/S),math.ceil(x2*SX/S)):
            floor[x,y] = material

fill_ref_rect(310,200,330,438,8)
fill_ref_rect(302,323,347,342,9)
fill_ref_rect(345,365,365,384,15)  # VIP window staircase in the 2D adaptation.
fill_ref_rect(207,158,229,199,15)  # Apartments -> B balcony.
fill_ref_rect(551,188,580,227,0)
fill_ref_rect(271,464,307,488,0)

def greedy_rectangles(cells):
    left = set(cells)
    result=[]
    while left:
        x,y=min(left,key=lambda p:(p[1],p[0]))
        width=1
        while (x+width,y) in left:
            width+=1
        height=1
        while all((xx,y+height) in left for xx in range(x,x+width)):
            height+=1
        for yy in range(y,y+height):
            for xx in range(x,x+width):
                left.remove((xx,yy))
        result.append((x*S,y*S,width*S,height*S))
    return result

blocked = {(x,y) for y in range(H) for x in range(W)} - set(floor)
wall_rects=greedy_rectangles(blocked)

# Distinctive landmarks use independent silhouettes and world footprints.
# (node name, atlas, radar center, world visual width, world collision rectangle)
PLACEMENTS = [
    ('BVan','van',(109,195),57,(-23,-43,46,86)),
    ('BDefault','ammo_crates',(187,239),72,(-27,-24,54,48)),
    ('BBoost','crates',(161,218),48,(-18,-16,36,32)),
    ('BBench','bench',(108,270),66,(-28,-11,56,22)),
    ('BEmpty','column',(212,282),29,(-11,-11,22,22)),
    ('MarketStall','market_stall',(160,352),78,(-32,-26,64,52)),
    ('MarketPottery','pottery',(217,357),38,(-12,-12,24,24)),
    ('MidBoxes','crates',(544,378),77,(-30,-25,60,50)),
    ('MidChair','bench',(436,401),32,(-13,-7,26,14)),
    ('ADefault','ammo_crates',(452,581),73,(-27,-25,54,50)),
    ('ATriple','crates',(404,600),62,(-24,-23,48,46)),
    ('AFirebox','crates',(478,626),43,(-17,-16,34,32)),
    ('ATetris','crates',(484,520),69,(-27,-22,54,44)),
    ('ATicket','market_stall',(349,642),56,(-22,-19,44,38)),
    ('PalacePillar1','column',(567,602),36,(-13,-13,26,26)),
    ('PalacePillar2','column',(600,617),36,(-13,-13,26,26)),
    ('TPottery','pottery',(706,313),39,(-13,-12,26,24)),
    ('ApartmentsRug','rugs',(280,153),54,None),
    ('PalaceRug','rugs',(646,612),58,None),
    ('CTPalm','palm',(208,537),114,None),
    ('APalm','palm',(552,661),134,None),
    ('BExteriorPalm','palm',(72,135),132,None),
    ('TExteriorPalm','palm',(747,280),146,None),
]

def world(p): return (round(p[0]*SX,2),round(p[1]*SY,2))
def vec(v): return f'Vector2({v[0]}, {v[1]})'
def poly(points): return 'PackedVector2Array('+', '.join(str(v) for p in points for v in p)+')'
def rect_points(w,h): return [(0,0),(w,0),(w,h),(0,h)]
def tile_bytes(cells):
    # Format version uint16(0), then six little-endian uint16 per native cell:
    # cell x/y, source id, atlas x/y, alternative id.
    return base64.b64encode(b'\x00\x00'+b''.join(struct.pack('<hhhhhh',x,y,0,t%4,t//4,0) for (x,y),t in sorted(cells.items()))).decode()

resources=[
    '[ext_resource type="Script" path="res://scene/pvp/maps/mirage_map.gd" id="Map"]',
    '[ext_resource type="TileSet" path="res://resources/texture/pvp/mirage_tileset.tres" id="Tiles"]',
]
for name in PROPS:
    resources.append(f'[ext_resource type="Texture2D" path="res://resources/texture/pvp/{name}.tres" id="{name}"]')
near_buildings = {(x,y) for x,y in blocked if any((x+dx,y+dy) in floor for dx in range(-3,4) for dy in range(-3,4))}
nodes=['[node name="MirageMap" type="Node2D"]','texture_filter = 2','script = ExtResource("Map")',
    '', '[node name="DesertBackdrop" type="Polygon2D" parent="."]',
    'z_index = -22',f'polygon = {poly([(-640,-480),(2560,-480),(2560,2080),(-640,2080)])}',
    'color = Color(0.18, 0.165, 0.145, 1)',
    '', '[node name="Ground" type="TileMapLayer" parent="."]',
    'z_index = -20', f'scale = Vector2({S/313}, {S/313})',
    'tile_set = ExtResource("Tiles")','collision_enabled = false','navigation_enabled = false','occlusion_enabled = false',
    f'tile_map_data = PackedByteArray("{tile_bytes({p:2 for p in set(floor)|near_buildings})}")',
    '', '[node name="WalkableFloor" type="TileMapLayer" parent="."]',
    'z_index = -19',f'scale = Vector2({S/313}, {S/313})',
    'tile_set = ExtResource("Tiles")','collision_enabled = false','navigation_enabled = false','occlusion_enabled = false',
    f'tile_map_data = PackedByteArray("{tile_bytes(floor)}")',
    '', '[node name="Buildings" type="TileMapLayer" parent="."]',
    'z_index = -18', f'scale = Vector2({S/313}, {S/313})',
    'self_modulate = Color(0.66, 0.65, 0.62, 1)',
    'tile_set = ExtResource("Tiles")','collision_enabled = false','navigation_enabled = false','occlusion_enabled = false',
    f'tile_map_data = PackedByteArray("{tile_bytes({(x,y):(6 if 16<x<25 and 18<y<30 else (7 if y<12 else 5)) for x,y in near_buildings})}")',
    '', '[node name="Walls" type="Node2D" parent="."]']

# One static body + native rectangle shape + native occluder per merged mass.
# The scene, collision geometry, and visual footprint share the same coordinates.
for i,(x,y,w,h) in enumerate(wall_rects):
    name=f'Wall{i:03d}'
    resources += ['',f'[sub_resource type="RectangleShape2D" id="Shape{i}"]',f'size = Vector2({w}, {h})',
        '',f'[sub_resource type="OccluderPolygon2D" id="Occluder{i}"]',f'polygon = {poly(rect_points(w,h))}']
    nodes += ['', f'[node name="{name}" type="StaticBody2D" parent="Walls" groups=["mirage_obstacle"]]',
        f'position = Vector2({x}, {y})','collision_layer = 1','collision_mask = 0',
        f'metadata/obstacle_rect = Rect2(0, 0, {w}, {h})',
        '',f'[node name="Collision" type="CollisionShape2D" parent="Walls/{name}"]',
        f'position = Vector2({w/2}, {h/2})',f'shape = SubResource("Shape{i}")',
        '', f'[node name="Occluder" type="LightOccluder2D" parent="Walls/{name}"]',f'occluder = SubResource("Occluder{i}")']

# Wall edges are continuous facades with a visible 8 px sandstone face. Draw
# only walkable-facing boundaries, never rectangle merge seams inside buildings.
nodes += ['', '[node name="Facades" type="Node2D" parent="."]','z_index = -16']
edge_num=0
for x,y in sorted(blocked):
    for dx,dy,points in [(-1,0,[(x*S,y*S),(x*S,(y+1)*S)]),(1,0,[((x+1)*S,y*S),((x+1)*S,(y+1)*S)]),(0,-1,[(x*S,y*S),((x+1)*S,y*S)]),(0,1,[(x*S,(y+1)*S),((x+1)*S,(y+1)*S)])]:
        if (x+dx,y+dy) not in floor: continue
        nodes += ['',f'[node name="Edge{edge_num}" type="Line2D" parent="Facades"]',
            f'points = {poly(points)}','width = 7.0',
            'default_color = Color(0.42, 0.32, 0.22, 1)' if dy==1 else 'default_color = Color(0.76, 0.65, 0.46, 1)']
        edge_num+=1

nodes += ['', '[node name="Landmarks" type="Node2D" parent="."]','z_index = -5']
prop_rects=[]
for name,art,ref_center,width,collision in PLACEMENTS:
    cx,cy=world(ref_center)
    bounds=PROPS[art]
    bbox=props_image.crop(bounds).getchannel('A').getbbox()
    scale=width/(bbox[2]-bbox[0])
    nodes += ['',f'[node name="{name}" type="Node2D" parent="Landmarks"]',f'position = Vector2({cx}, {cy})',
        '', f'[node name="Artwork" type="Sprite2D" parent="Landmarks/{name}"]',
        f'texture = ExtResource("{art}")',f'scale = Vector2({scale}, {scale})']
    if collision:
        rx,ry,w,h=collision
        prop_rects.append((cx+rx,cy+ry,w,h))
        resources += ['',f'[sub_resource type="RectangleShape2D" id="Shape{name}"]',f'size = Vector2({w}, {h})',
            '',f'[sub_resource type="OccluderPolygon2D" id="Occluder{name}"]',f'polygon = {poly([(rx,ry),(rx+w,ry),(rx+w,ry+h),(rx,ry+h)])}']
        nodes += ['',f'[node name="Body" type="StaticBody2D" parent="Landmarks/{name}" groups=["mirage_obstacle"]]',
            'collision_layer = 1','collision_mask = 0',f'metadata/obstacle_rect = Rect2({rx}, {ry}, {w}, {h})',
            '', f'[node name="Collision" type="CollisionShape2D" parent="Landmarks/{name}/Body"]',
            f'position = Vector2({rx+w/2}, {ry+h/2})',f'shape = SubResource("Shape{name}")',
            '', f'[node name="Occluder" type="LightOccluder2D" parent="Landmarks/{name}/Body"]',f'occluder = SubResource("Occluder{name}")']

# Architectural portals retain an actual opening. Pillars sit within wall ends;
# their decorative overhead arch becomes translucent near players in map script.
nodes += ['', '[node name="Archways" type="Node2D" parent="."]','z_index = 5']
for name,center,width in [('ARampArch',(614,512),110),('BArch',(300,231),98),('PalaceArch',(642,562),92),('MarketDoor',(214,311),80)]:
    cx,cy=world(center)
    nodes += ['',f'[node name="{name}" type="Sprite2D" parent="Archways" groups=["mirage_arch"]]',
        f'position = Vector2({cx}, {cy})','texture = ExtResource("arch")',f'scale = Vector2({width/360}, {width/360})',
        'modulate = Color(1, 1, 1, 0.82)']
    # The artwork has a transparent opening; only the two visible stone piers
    # collide. Bodies remain siblings so their real world extents do not inherit
    # the artwork's source-pixel scale.
    for side,rx in [('Left',-width*0.40),('Right',width*0.25)]:
        ry,w,h = -width*0.42,width*0.15,width*0.84
        pier = name+side
        prop_rects.append((cx+rx,cy+ry,w,h))
        resources += ['',f'[sub_resource type="RectangleShape2D" id="Shape{pier}"]',f'size = Vector2({w}, {h})',
            '',f'[sub_resource type="OccluderPolygon2D" id="Occluder{pier}"]',f'polygon = {poly(rect_points(w,h))}']
        nodes += ['',f'[node name="{pier}" type="StaticBody2D" parent="Archways" groups=["mirage_obstacle"]]',
            f'position = Vector2({cx+rx}, {cy+ry})','collision_layer = 1','collision_mask = 0',
            f'metadata/obstacle_rect = Rect2(0, 0, {w}, {h})',
            '',f'[node name="Collision" type="CollisionShape2D" parent="Archways/{pier}"]',
            f'position = Vector2({w/2}, {h/2})',f'shape = SubResource("Shape{pier}")',
            '',f'[node name="Occluder" type="LightOccluder2D" parent="Archways/{pier}"]',f'occluder = SubResource("Occluder{pier}")']

nodes += ['', '[node name="SiteMarkings" type="Node2D" parent="."]','z_index = -10']
for site,center,color in [('A',(442,611),(0.76,0.27,0.12,0.9)),('B',(187,244),(0.76,0.27,0.12,0.9))]:
    cx,cy=world(center)
    letter_y = cy + 58 if site == 'B' else cy
    nodes += ['',f'[node name="{site}Boundary" type="Line2D" parent="SiteMarkings"]',
        f'points = {poly([(cx-66,cy-48),(cx+66,cy-48),(cx+66,cy+48),(cx-66,cy+48),(cx-66,cy-48)])}',
        'width = 2.2',f'default_color = Color{color}',
        '',f'[node name="{site}Letter" type="Label" parent="SiteMarkings"]',
        f'offset_left = {cx-24}',f'offset_top = {letter_y-20}',f'offset_right = {cx+24}',f'offset_bottom = {letter_y+24}',
        'theme_override_colors/font_color = Color(0.75, 0.23, 0.11, 0.92)','theme_override_font_sizes/font_size = 38',f'text = "{site}"','horizontal_alignment = 1']

nodes += ['', '[node name="Spawns" type="Node2D" parent="."]']
SPAWNS={'CT':[(250,559),(252,581),(253,537),(215,565),(269,603),(207,579),(244,606),(265,573)],'T':[(698,277),(698,300),(698,344),(698,365),(698,387),(683,325),(713,354),(712,397)]}
BUY={'CT':(440,1130,255,215),'T':(1595,550,175,335)}
for team,spawns in SPAWNS.items():
    nodes += ['',f'[node name="{team}" type="Node2D" parent="Spawns"]']
    for i,center in enumerate(spawns):
        nodes += ['', f'[node name="Spawn{i}" type="Marker2D" parent="Spawns/{team}"]', f'position = {vec(world(center))}']

nodes += ['', '[node name="BuyZones" type="Node2D" parent="."]','z_index = -12']
for team,(x,y,w,h) in BUY.items():
    col='Color(0.28, 0.67, 0.92, 0.6)' if team=='CT' else 'Color(0.92, 0.65, 0.22, 0.6)'
    nodes += ['',f'[node name="{team}" type="Node2D" parent="BuyZones"]',f'position = Vector2({x}, {y})',
        f'metadata/buy_rect = Rect2(0, 0, {w}, {h})',
        '',f'[node name="Outline" type="Line2D" parent="BuyZones/{team}"]',
        f'points = {poly(rect_points(w,h)+[(0,0)])}','width = 2.0',f'default_color = {col}']

# Human editable named region markers provide runtime callouts and minimap data.
nodes += ['', '[node name="Callouts" type="Node2D" parent="."]']
CHINESE={'B Site':'B 点','B Apartments':'B 公寓','Back Alley':'后巷','House':'电视房','T Alley':'T 后巷','T Spawn':'T 出生区','Side Alley':'侧巷','Top Mid':'中路远端','Mid':'中路','Catwalk':'猫道','B Short':'B 小','Ladder Room':'梯子房','Window':'VIP / 窗口','Underpass':'下水道','Market':'超市','CT Passage':'警家通道','Jungle':'丛林','Connector':'拱门','A Site':'A 点','CT Spawn':'CT 出生区','A Ramp':'A1 / A 坡','Palace Entrance':'宫殿通道','Palace':'A2 / 宫殿'}
for i,(label,_,polygon) in enumerate(AREAS):
    xs=[p[0]*SX for p in polygon]; ys=[p[1]*SY for p in polygon]
    nodes += ['',f'[node name="Region{i:02}" type="Marker2D" parent="Callouts"]',
        f'position = Vector2({sum(xs)/len(xs)}, {sum(ys)/len(ys)})',f'metadata/callout = "{CHINESE[label]}"',
        f'metadata/region = {poly([world(p) for p in polygon])}']

scene='[gd_scene format=3]\n\n'+'\n'.join(resources)+'\n\n'+'\n'.join(nodes)+'\n'
(OUT/'mirage_map.tscn').write_text(scene, encoding='utf8')

# Pure topology validation: every route and spawn must be reachable. Physics and
# rendered visibility are checked separately inside Godot by verify_mirage_pvp.
start=next(iter(floor)); seen={start}; queue=deque([start])
while queue:
    x,y=queue.popleft()
    for p in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)]:
        if p in floor and p not in seen: seen.add(p); queue.append(p)
assert len(seen)==len(floor), f'Disconnected floor: {set(floor)-seen}'
for team,spawns in SPAWNS.items():
    for point in spawns:
        px,py=world(point)
        assert (int(px//32),int(py//32)) in floor, (team,point,'spawn in wall')
        for rx,ry,w,h in prop_rects:
            assert not (rx-10<px<rx+w+10 and ry-10<py<ry+h+10), (team,point,'spawn in prop')
# Check actual movement clearance around the separately placed props and arch
# piers, beyond mere floor connectivity. 8 px probes with a conservative 9 px
# footprint guarantee all 16 team starts can reach both ends of the map.
clear_cells=set()
obstacles=wall_rects+prop_rects
for yy in range(H*4):
    for xx in range(W*4):
        if (xx//4,yy//4) not in floor: continue
        px,py=xx*8+4,yy*8+4
        if all(not (rx-9<px<rx+w+9 and ry-9<py<ry+h+9) for rx,ry,w,h in obstacles):
            clear_cells.add((xx,yy))
def closest_clear(point):
    px,py=point
    return min(clear_cells,key=lambda c: (c[0]*8+4-px)**2+(c[1]*8+4-py)**2)
initial=closest_clear(world(SPAWNS['CT'][0])); accessible={initial}; queue=deque([initial])
while queue:
    x,y=queue.popleft()
    for p in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)]:
        if p in clear_cells and p not in accessible: accessible.add(p); queue.append(p)
for team,spawns in SPAWNS.items():
    for point in spawns:
        assert closest_clear(world(point)) in accessible, (team,point,'spawn trapped by props')
for label,_,polygon in AREAS:
    point=world((sum(p[0] for p in polygon)/len(polygon),sum(p[1] for p in polygon)/len(polygon)))
    assert closest_clear(point) in accessible, (label,'route isolated by props')
report={'world_size':[W*S,H*S],'walkable_tiles':len(floor),'wall_rectangles':len(wall_rects),'landmark_count':len(PLACEMENTS),'collidable_landmarks':len(prop_rects),'facade_edges':edge_num,'connected':True,'clearance_probe_cells':len(clear_cells),'accessible_probe_cells':len(accessible),'native_alpha':True,'spawns':SPAWNS,'references':['https://totalcsgo.com/callouts/mirage','https://docs.godotengine.org/en/stable/tutorials/2d/using_tilesets.html'],'adaptation':'Single-plane 2D: underpass offset beside VIP, walkable window and balcony steps; no bomb gameplay in elimination PVP.'}
(ROOT/'dev_tools/generated_sources/mirage_pvp/map_build_report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf8')
print(json.dumps(report,ensure_ascii=False))
