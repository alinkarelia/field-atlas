"""Reviewable memorial-to-person links. Never merges or overwrites people."""
import hashlib
import json
import re
import time
import unicodedata
from .store import Problem, identifier, dump

def digest(value):
    return hashlib.sha256(json.dumps(value,sort_keys=True,ensure_ascii=False,separators=(',',':')).encode()).hexdigest()

def normal_name(value):
    value=unicodedata.normalize('NFKC',value).lower().translate(str.maketrans({'ё':'е','ѣ':'е','і':'и','ѳ':'ф'}))
    return re.findall(r'[a-zа-я]+',re.sub(r'ъ\b','',value))

def date_parts(value):
    value=str(value or '').strip()
    if re.fullmatch(r'\d{4}',value):return (int(value),None,None)
    if re.fullmatch(r'\d{4}-\d{2}-\d{2}',value):return tuple(map(int,value.split('-')))
    if re.fullmatch(r'\d{2}\.\d{2}\.\d{4}',value):
        day,month,year=map(int,value.split('.'));return year,month,day
    return None

def compare(reading,person):
    left,right=normal_name(reading.get('name','')),normal_name(person['name'])
    shared=set(left)&set(right);reasons=[];conflicts=[];score=0
    if left and sorted(left)==sorted(right):
        score+=5 if len(left)>1 else 1;reasons.append('Совпадает имя' if len(left)>1 else 'Совпадает только одно слово имени')
    elif shared:
        score+=min(len(shared),2);reasons.append('Совпали части имени: '+', '.join(sorted(shared)))
    else:return None
    if left and right and not (set(left)<=set(right) or set(right)<=set(left)):
        conflicts.append('Части имени различаются')
    for field,label in [('birth','рождения'),('death','смерти')]:
        a,b=date_parts(reading.get(field)),date_parts(person.get(field))
        if a and b:
            if any(x is not None and y is not None and x!=y for x,y in zip(a,b)):
                conflicts.append('Различается дата '+label)
            else:score+=3;reasons.append('Совпадает известная часть даты '+label)
        elif reading.get(field) and person.get(field):reasons.append('Дата '+label+' неполная — нужна ручная сверка')
    return {'score':score,'reasons':reasons,'conflicts':conflicts,'strength':'contradiction' if conflicts else 'review' if score>=8 else 'weak'}

class Identity:
    def __init__(self,store):
        self.store=store
        with store.lock,store.db:
            store.db.executescript('''
            CREATE TABLE IF NOT EXISTS archive_people(key TEXT PRIMARY KEY, data TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS identity_links(id TEXT PRIMARY KEY, data TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS identity_audit(seq INTEGER PRIMARY KEY AUTOINCREMENT, data TEXT NOT NULL);
            ''')

    def import_people(self,payload):
        if payload.get('schema')!='field-people-v1':raise Problem(400,'Нужен экспорт field-people-v1')
        source=identifier(payload.get('source'));people=payload.get('people')
        if not isinstance(people,list) or not 1<=len(people)<=5000:raise Problem(400,'Ожидается от 1 до 5000 карточек людей')
        prepared=[];seen=set()
        for item in people:
            if not isinstance(item,dict):raise Problem(400,'Некорректная карточка человека')
            pid=identifier(item.get('id'))
            if pid in seen:raise Problem(400,'Повтор ID человека в экспорте')
            seen.add(pid)
            fields={key:item.get(key,'') for key in ('name','birth','death','place','url')}
            if any(not isinstance(v,str) or len(v)>1000 for v in fields.values()) or not fields['name'].strip():raise Problem(400,'Укажите имя; поля должны быть текстом')
            if fields['url'] and not fields['url'].startswith('https://'):raise Problem(400,'Ссылка карточки должна начинаться с https://')
            person={'id':pid,'source':source,**fields,'synthetic':payload.get('synthetic') is True}
            person['key']=digest([source,pid]);person['revision']=digest(person);prepared.append(person)
        with self.store.lock,self.store.db:
            for p in prepared:self.store.db.execute('INSERT OR REPLACE INTO archive_people VALUES(?,?)',(p['key'],dump(p)))
        return {'imported':len(prepared),'source':source,'mode':'local-copy'}

    def people(self):
        with self.store.lock:return [json.loads(r[0]) for r in self.store.db.execute('SELECT data FROM archive_people')]

    def record(self,rid):
        identifier(rid)
        with self.store.lock:row=self.store.db.execute('SELECT data,version FROM records WHERE id=?',(rid,)).fetchone()
        if not row:raise Problem(404,'Сначала передайте карточку захоронения')
        record=json.loads(row['data'])
        if record.get('kind')!='grave' or record.get('deleted'):raise Problem(400,'Связи с людьми доступны для карточки захоронения')
        return record,row['version']

    def token(self,record,slot,person):
        # Version of evidence, independent of transport metadata and cosmetic autosaves.
        evidence={k:record.get(k) for k in ('id','projectId','persons','transcription','photos','point','noInscription','unreadable')}
        return digest([evidence,slot,person['revision'],'inscription_refers_to'])

    def link_state(self,link):
        try:
            record,_=self.record(link['recordId']);person=next(p for p in self.people() if p['key']==link['personKey'])
            stale=self.token(record,link['slot'],person)!=link['token']
        except (Problem,StopIteration):stale=True
        return {**link,'needsReview':stale,'effectiveState':'needs_review' if stale else link['state']}

    def links(self,pid):
        self.store.project(pid)
        with self.store.lock:
            return [self.link_state(link) for r in self.store.db.execute('SELECT data FROM identity_links') if (link:=json.loads(r[0]))['projectId']==pid]

    def candidates(self,rid):
        with self.store.lock:
            record,version=self.record(rid);people=self.people();links={l['id']:l for l in self.links(record['projectId'])};groups=[]
            for slot,reading in enumerate(record.get('persons',[])):
                if not isinstance(reading,dict):continue
                matches=[]
                for person in people:
                    comparison=compare(reading,person)
                    if comparison is None:continue
                    lid=digest([rid,slot,person['key']]);token=self.token(record,slot,person)
                    matches.append({'id':lid,'slot':slot,'person':person,'token':token,**comparison,'link':links.get(lid)})
                matches.sort(key=lambda m:(bool(m['conflicts']),-m['score'],m['person']['name']))
                groups.append({'slot':slot,'reading':reading,'candidates':matches[:12],'total':len(matches)})
            return {'recordId':rid,'serverVersion':version,'groups':groups,'peopleCount':len(people)}

    def decide(self,payload):
        state=payload.get('state');rid=identifier(payload.get('recordId'));slot=payload.get('slot');key=payload.get('personKey')
        note=payload.get('evidence','').strip() if isinstance(payload.get('evidence',''),str) else ''
        if state not in ('confirmed','rejected','revoked') or type(slot) is not int or slot<0:raise Problem(400,'Некорректное решение')
        if not 8<=len(note)<=2000:raise Problem(400,'Опишите основание решения: от 8 до 2000 символов')
        with self.store.lock,self.store.db:
            record,version=self.record(rid)
            if slot>=len(record.get('persons',[])):raise Problem(409,'Состав людей на плите изменился')
            person=next((p for p in self.people() if p['key']==key),None)
            if not person:raise Problem(404,'Карточка человека не найдена')
            token=self.token(record,slot,person)
            if token!=payload.get('token'):raise Problem(409,'Исходные сведения изменились. Обновите сравнение.')
            comparison=compare(record['persons'][slot],person)
            if not comparison:raise Problem(400,'Сначала уточните имя в карточке захоронения')
            if state=='confirmed' and comparison['conflicts']:raise Problem(409,'Есть противоречия. Уточните исходные сведения перед подтверждением.')
            lid=digest([rid,slot,key])
            old=self.store.db.execute('SELECT data FROM identity_links WHERE id=?',(lid,)).fetchone()
            previous=json.loads(old[0]) if old else None
            if state=='revoked' and (not previous or previous['state']!='confirmed'):raise Problem(409,'Нет подтверждённой связи для отзыва')
            if state=='confirmed':
                for link in self.links(record['projectId']):
                    if link['recordId']==rid and link['slot']==slot and link['id']!=lid and link['effectiveState']=='confirmed':
                        raise Problem(409,'Этот человек на плите уже связан с другой карточкой. Сначала отзовите прежнюю связь.')
            link={'id':lid,'projectId':record['projectId'],'recordId':rid,'slot':slot,'personKey':key,'personSource':person['source'],'personId':person['id'],'relation':'inscription_refers_to','state':state,'token':token,'evidence':note,'recordVersion':version,'decidedAt':time.time(),'actor':'local-reviewer'}
            # Retrying the same decision is safe and does not create audit duplicates.
            if previous and all(previous.get(k)==link.get(k) for k in ('state','token','evidence')):return self.link_state(previous)
            self.store.db.execute('INSERT OR REPLACE INTO identity_links VALUES(?,?)',(lid,dump(link)))
            self.store.db.execute('INSERT INTO identity_audit(data) VALUES(?)',(dump({'before':previous,'after':link}),))
            return self.link_state(link)

    def export(self,pid):
        with self.store.lock:
            records=[r for r in self.store.records(pid) if r.get('kind')=='grave' and not r.get('deleted')]
            links=self.links(pid);keys={l['personKey'] for l in links};people=[p for p in self.people() if p['key'] in keys]
            audit=[json.loads(r[0]) for r in self.store.db.execute('SELECT data FROM identity_audit') if json.loads(r[0])['after']['projectId']==pid]
            return {'schema':'field-graph-v1','project':self.store.project(pid),'memorials':records,'people':people,'links':links,'audit':audit,'mergePeople':False}
