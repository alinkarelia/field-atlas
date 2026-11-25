"""Validate the portable plan before storing measurements from any client."""
import math


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def point(value):
    return isinstance(value, list) and len(value) == 2 and all(number(v) and abs(v) < 100000 for v in value)


def polygon(points):
    if not isinstance(points, list) or not 3 <= len(points) <= 500 or not all(point(p) for p in points):
        return False
    def cross(a, b, c):
        return (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])
    pairs = list(zip(points, points[1:]+points[:1]))
    if abs(sum(a[0]*b[1]-b[0]*a[1] for a, b in pairs))/2 < .1:
        return False
    for i, (a, b) in enumerate(pairs):
        if math.dist(a, b) < .05:
            return False
        for j, (c, d) in enumerate(pairs[i+1:], i+1):
            if j == i+1 or i == 0 and j == len(pairs)-1:
                continue
            boxes = all(max(min(a[k], b[k]), min(c[k], d[k])) <= min(max(a[k], b[k]), max(c[k], d[k]))+1e-8 for k in (0, 1))
            if boxes and cross(a, b, c)*cross(a, b, d) <= 0 and cross(c, d, a)*cross(c, d, b) <= 0:
                return False
    return True


def validate_ceiling(value):
    def require(ok, message):
        if not ok: raise ValueError(message)
    require(isinstance(value, dict) and value.get('schema') == 'field-ceiling-v1' and value.get('reviewed') is True, 'Потолок требует отдельного подтверждённого замера')
    method=value.get('method')
    require(method in ('manual-height','manual-corners','plane-proposal'), 'Неизвестный метод замера потолка')
    if method=='manual-height':
        h=value.get('manualHeight');source=value.get('source')
        require(number(h) and .5<=h<=30 and isinstance(source,str) and 3<=len(source.strip())<=500, 'Некорректная высота или источник замера потолка')
        return [h]
    def point3(p):return isinstance(p,list) and len(p)==3 and all(number(v) and abs(v)<100000 for v in p)
    floor=value.get('floorPoint');points=value.get('points');frame=value.get('frameId')
    require(isinstance(frame,str) and 0<len(frame)<=200 and point3(floor) and isinstance(points,list) and 3<=len(points)<=500 and all(point3(p) for p in points), 'Некорректные точки потолка')
    heights=[p[2]-floor[2] for p in points]
    require(all(.5<=h<=30 for h in heights) and polygon([p[:2] for p in points]), 'Некорректный контур или высота потолка')
    return heights


def validate_plan(doc):
    def require(condition, message):
        if not condition:
            raise ValueError(message)
    def named(value):
        return isinstance(value, str) and 0 < len(value) <= 200
    require(isinstance(doc, dict) and doc.get('schema') == 'field-room-plan-v1' and named(doc.get('frameId')), 'Некорректная система координат плана')
    rooms = doc.get('rooms')
    require(isinstance(rooms, list) and 1 <= len(rooms) <= 100, 'Некорректный список комнат')
    room_ids = set()
    for room in rooms:
        require(isinstance(room, dict) and named(room.get('id')) and room['id'] not in room_ids and named(room.get('name')) and type(room.get('level', 0)) is int and -20 <= room.get('level', 0) <= 200, 'Некорректная комната')
        room_ids.add(room['id'])
        walls, openings = room.get('walls'), room.get('openings')
        require(isinstance(walls, list) and 1 <= len(walls) <= 500 and isinstance(openings, list) and len(openings) <= 1000, 'Некорректный список стен или проёмов')
        index, identifiers = {}, set()
        for w in walls:
            require(isinstance(w, dict) and named(w.get('id')) and w['id'] not in identifiers and point(w.get('start')) and point(w.get('end')), 'Некорректная стена')
            length = math.dist(w['start'], w['end'])
            require(length >= .05 and number(w.get('height')) and 0 < w['height'] <= 100 and number(w.get('base')) and type(w.get('confidence')) is int and w['confidence'] in (0, 1, 2), 'Некорректные размеры стены')
            if w.get('profile') is not None:
                require(polygon(w['profile']) and all(-.1 <= p[0] <= length+.1 and -.1 <= p[1] <= w['height']+.1 for p in w['profile']), 'Некорректный контур высоты стены')
            index[w['id']] = w
            identifiers.add(w['id'])
        for o in openings:
            require(isinstance(o, dict) and named(o.get('id')) and o['id'] not in identifiers and isinstance(o.get('wallId'), str) and o['wallId'] in index and o.get('kind') in ('door', 'window', 'opening'), 'Проём не привязан к стене')
            w = index[o['wallId']]
            require(all(number(o.get(k)) for k in ('offset', 'width', 'height', 'sill')), 'Некорректные размеры проёма')
            require(o['offset'] >= -.03 and o['width'] > 0 and o['height'] > 0 and o['sill'] >= -.03 and o['offset']+o['width'] <= math.dist(w['start'], w['end'])+.05 and o['sill']+o['height'] <= w['height']+.1, 'Проём выходит за стену')
            identifiers.add(o['id'])
        if room.get('floor') is not None:
            require(polygon(room['floor']), 'Некорректный контур пола')
        if room.get('ceilingHeight') is not None:
            require(number(room['ceilingHeight']) and room['ceilingHeight'] > 0, 'Некорректная высота потолка')
        if room.get('ceiling') is not None:
            heights=validate_ceiling(room['ceiling'])
            require(not room['ceiling'].get('synthetic') or doc.get('synthetic'), 'Учебный потолок нельзя записать как реальный')
            if room.get('ceilingHeight') is not None:
                require(max(heights)-min(heights)<=.05 and abs(room['ceilingHeight']-sum(heights)/len(heights))<.01, 'Общая высота не соответствует отдельному замеру потолка')
        for key in ('ceilingSourceId',):
            require(room.get(key) is None or named(room[key]), 'Некорректная ссылка на исходник потолка')
        if room.get('ceilingSourceHistory') is not None:
            require(isinstance(room['ceilingSourceHistory'],list) and len(room['ceilingSourceHistory'])<=1000 and all(named(v) for v in room['ceilingSourceHistory']), 'Некорректная история потолка')
        if room.get('notes') is not None:
            require(isinstance(room['notes'], list) and len(room['notes']) <= 1000 and all(isinstance(n, str) and len(n) <= 2000 for n in room['notes']), 'Некорректные замечания к плану')
        if room.get('ceilingSource') is not None:
            require(isinstance(room['ceilingSource'], str), 'Некорректный источник высоты потолка')
        require(all(o.get('code') is None or isinstance(o['code'], str) and len(o['code']) <= 100 for o in walls+openings), 'Некорректная подпись элемента')
