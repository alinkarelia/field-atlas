import hashlib
import json
import math
import re
import sqlite3
import threading
import time
from pathlib import Path
from .room_plan import validate_plan

IDENT=re.compile(r'^[A-Za-z0-9_-]{1,100}$')
HASH=re.compile(r'^[0-9a-f]{64}$')

class Problem(Exception):
    def __init__(self,status,message,**details):
        self.status=status;self.message=message;self.details=details

def identifier(value):
    if not isinstance(value,str) or not IDENT.fullmatch(value):raise Problem(400,'Некорректный идентификатор')
    return value

def dump(value):return json.dumps(value,ensure_ascii=False,allow_nan=False,separators=(',',':'))

def valid_record(record):
    if not isinstance(record,dict):raise Problem(400,'Некорректная карточка')
    identifier(record.get('id'))
    identifier(record.get('projectId'))
    if record.get('kind') not in ('grave','boundary','road','path','tree','dump','obstacle','anomaly','entrance','object','room','facade','container','sector','plot'):
        raise Problem(400,'Неизвестный тип объекта')
    if len(dump(record).encode())>2*1024*1024:raise Problem(413,'Карточка слишком велика')
    if record.get('kind')=='grave' and record.get('status') not in ('draft','complete'):
        raise Problem(400,'Некорректный статус карточки')
    persons=record.get('persons',[])
    if not isinstance(persons,list) or len(persons)>2000 or any(not isinstance(p,dict) or any(not isinstance(p.get(k,''),str) or len(p.get(k,''))>2000 for k in ('name','birth','death')) for p in persons):
        raise Problem(400,'Некорректные сведения о людях')
    for key in ('point',):
        p=record.get(key)
        if p is not None and (not isinstance(p,list) or len(p)!=2 or not all(type(v) in (int,float) and math.isfinite(v) for v in p)):
            raise Problem(400,'Некорректные координаты')
    points=record.get('points',[])
    if not isinstance(points,list) or len(points)>50000 or any(not isinstance(p,list) or len(p)!=2 or not all(type(v) in (int,float) and math.isfinite(v) for v in p) for p in points):
        raise Problem(400,'Некорректная геометрия')
    return record

class Store:
    def __init__(self,root):
        self.root=Path(root).resolve();self.root.mkdir(parents=True,exist_ok=True)
        self.assets=self.root/'assets';self.assets.mkdir(exist_ok=True)
        self.lock=threading.RLock()
        self.db=sqlite3.connect(self.root/'atlas.sqlite3',check_same_thread=False)
        self.db.row_factory=sqlite3.Row
        self.db.executescript('''PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
        CREATE TABLE IF NOT EXISTS records(id TEXT PRIMARY KEY, version INTEGER NOT NULL, data TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS projects(id TEXT PRIMARY KEY,data TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS mutations(id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, response TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS uploads(id TEXT PRIMARY KEY, sha TEXT NOT NULL,size INTEGER NOT NULL,offset INTEGER NOT NULL DEFAULT 0,mime TEXT NOT NULL,complete INTEGER NOT NULL DEFAULT 0,project TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS assemblies(id TEXT PRIMARY KEY,data TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY,state TEXT NOT NULL,data TEXT NOT NULL);
        ''');self.db.commit()
        # A stopped process cannot keep an OCR worker alive. Make the interrupted job retryable.
        for row in self.db.execute("SELECT data FROM jobs WHERE state IN ('queued','running','cancelling')").fetchall():
            job=json.loads(row[0]);job.update(state='failed',error='Задание прервано перезапуском сервера. Исходники сохранены; повторите запрос.')
            self.db.execute('UPDATE jobs SET state=?,data=? WHERE id=?',('failed',dump(job),job['id']))
        self.db.commit()
    def close(self):
        if hasattr(self,'assembler'):self.assembler.close()
        self.db.close()
    def projects(self):
        with self.lock:return [json.loads(r[0]) for r in self.db.execute('SELECT data FROM projects')]
    def project(self,pid):
        identifier(pid)
        with self.lock:
            row=self.db.execute('SELECT data FROM projects WHERE id=?',(pid,)).fetchone()
            if not row:raise Problem(404,'Проект не найден')
            return json.loads(row[0])
    def save_project(self,p):
        identifier(p.get('id'))
        if p.get('type') not in ('cemetery','interior','exterior','land') or not isinstance(p.get('title'),str) or not 1<=len(p['title'].strip())<=160:
            raise Problem(400,'Укажите название и тип проекта')
        with self.lock,self.db:
            old=self.db.execute('SELECT data FROM projects WHERE id=?',(p['id'],)).fetchone()
            if old and json.loads(old[0])!=p:raise Problem(409,'Проект с этим ID уже существует')
            self.db.execute('INSERT OR IGNORE INTO projects VALUES(?,?)',(p['id'],dump(p)))
        return p
    def records(self,pid):
        self.project(pid)
        with self.lock:return [dict(json.loads(r['data']),serverVersion=r['version']) for r in self.db.execute('SELECT * FROM records') if json.loads(r['data']).get('projectId')==pid]
    def save_record(self,payload):
        record=valid_record(payload.get('record'));mid=identifier(payload.get('mutationId'))
        project=self.project(record['projectId'])
        if record['kind']=='grave' and project['type']!='cemetery':raise Problem(400,'Карточки захоронений доступны только в проекте кладбища')
        if record.get('roomPlan') is not None:
            if project['type']!='interior' or record['kind']!='room':raise Problem(400,'План помещения доступен только в карточке комнаты внутри здания')
            plan=record['roomPlan']
            try:validate_plan(plan)
            except ValueError as error:raise Problem(400,str(error)) from error
            if plan.get('synthetic') and not project.get('synthetic'):raise Problem(400,'Учебный план нельзя записать как реальные измерения')
        base=payload.get('baseVersion')
        if type(base) is not int or base<0:raise Problem(400,'Некорректная версия')
        encoded=dump(record);fingerprint=hashlib.sha256(dump({'record':record,'baseVersion':base}).encode()).hexdigest()
        with self.lock,self.db:
            old=self.db.execute('SELECT * FROM mutations WHERE id=?',(mid,)).fetchone()
            if old:
                if old['fingerprint']!=fingerprint:raise Problem(409,'Идентификатор запроса уже использован для других данных')
                return json.loads(old['response'])
            current=self.db.execute('SELECT * FROM records WHERE id=?',(record['id'],)).fetchone()
            if current and json.loads(current['data'])['projectId']!=record['projectId']:raise Problem(409,'Нельзя перенести объект в другой проект заменой ID')
            version=current['version'] if current else 0
            if version!=base:raise Problem(409,'Карточка изменена на сервере',serverVersion=version,serverRecord=json.loads(current['data']) if current else None)
            response={'id':record['id'],'version':version+1}
            self.db.execute('INSERT OR REPLACE INTO records VALUES(?,?,?)',(record['id'],version+1,encoded))
            self.db.execute('INSERT INTO mutations VALUES(?,?,?)',(mid,fingerprint,dump(response)))
            return response
    def init_upload(self,p):
        uid=identifier(p.get('id'));sha=p.get('sha256');size=p.get('size');mime=p.get('mime','application/octet-stream')
        pid=identifier(p.get('projectId'));self.project(pid)
        if not isinstance(sha,str) or not HASH.fullmatch(sha) or type(size) is not int or not 1<=size<=512*1024**2:
            raise Problem(400,'Некорректный размер или контрольная сумма')
        if mime not in ('application/json','image/jpeg','image/png','image/heic','application/octet-stream'):
            raise Problem(400,'Неподдерживаемый тип файла')
        with self.lock,self.db:
            old=self.db.execute('SELECT * FROM uploads WHERE id=?',(uid,)).fetchone()
            if old and (old['sha']!=sha or old['size']!=size or old['mime']!=mime or old['project']!=pid):raise Problem(409,'Файл с этим ID имеет другое содержимое или проект')
            if not old:self.db.execute('INSERT INTO uploads(id,sha,size,mime,project) VALUES(?,?,?,?,?)',(uid,sha,size,mime,pid))
            return self.upload_status(uid)
    def upload_status(self,uid):
        identifier(uid)
        with self.lock:
            row=self.db.execute('SELECT * FROM uploads WHERE id=?',(uid,)).fetchone()
            if not row:raise Problem(404,'Загрузка не найдена')
            return dict(row)
    def append(self,uid,offset,data):
        with self.lock:
            s=self.upload_status(uid)
            if s['complete']:raise Problem(409,'Файл уже завершён',offset=s['offset'])
            if type(offset) is not int or offset!=s['offset']:raise Problem(409,'Продолжите с подтверждённого смещения',offset=s['offset'])
            if not data or len(data)>4*1024**2 or offset+len(data)>s['size']:raise Problem(400,'Неверный размер части')
            path=self.assets/uid
            if offset and (not path.exists() or path.stat().st_size<offset):raise Problem(500,'Локальный файл повреждён')
            with path.open('r+b' if path.exists() else 'wb') as f:
                f.seek(offset);f.truncate();f.write(data);f.flush()
                import os;os.fsync(f.fileno())
            with self.db:self.db.execute('UPDATE uploads SET offset=? WHERE id=?',(offset+len(data),uid))
            return self.upload_status(uid)
    def complete(self,uid):
        with self.lock:
            s=self.upload_status(uid)
            if s['complete']:return s
            if s['offset']!=s['size']:raise Problem(409,'Переданы не все части',offset=s['offset'])
            path=self.assets/uid;hasher=hashlib.sha256()
            with path.open('rb') as f:
                for block in iter(lambda:f.read(1024**2),b''):hasher.update(block)
            if hasher.hexdigest()!=s['sha']:raise Problem(422,'Контрольная сумма не совпала; исходник сохранён для проверки')
            with self.db:self.db.execute('UPDATE uploads SET complete=1 WHERE id=?',(uid,))
            return self.upload_status(uid)
    def asset(self,uid):
        s=self.upload_status(uid)
        if not s['complete']:raise Problem(409,'Файл ещё не принят полностью')
        return self.assets/uid,s
    def put_assembly(self,aid,data):
        identifier(aid)
        directory=self.root/'derived'/aid;directory.mkdir(parents=True,exist_ok=True)
        index=[]
        for key,points in data['tiles'].items():
            identifier(key);file=directory/(key+'.json');temporary=file.with_suffix('.tmp')
            temporary.write_text(dump({'schema':'field-tile-v1','frameId':data['referenceFrame'],'points':points}),encoding='utf-8');temporary.replace(file)
            index.append({'id':key,'pointCount':len(points),'url':f'/api/assemblies/{aid}/tiles/{key}'})
        summary={k:v for k,v in data.items() if k!='tiles'}
        summary['tiles']=index;summary['coveragePreviewTruncated']=len(data['coverage'])>50000;summary['coverage']=data['coverage'][:50000]
        with self.lock,self.db:self.db.execute('INSERT OR REPLACE INTO assemblies VALUES(?,?)',(aid,dump(summary)))
        return summary
    def assembly_tile(self,aid,key,kind='points',page=None):
        identifier(aid);identifier(key)
        with self.lock:
            row=self.db.execute('SELECT data FROM assemblies WHERE id=?',(aid,)).fetchone()
            if not row or key not in {t['id'] for t in json.loads(row[0])['tiles']}:raise Problem(404,'Часть модели не найдена')
            tile=next(t for t in json.loads(row[0])['tiles'] if t['id']==key)
            if page is not None:
                if type(page) is not int or page<0 or page>=tile.get('pages',0):raise Problem(404,'Страница сектора не найдена')
                return (self.root/'derived'/aid/(key+f'.page-{page}.json')).read_bytes()
            if kind=='points' and tile.get('pages',0)>5:raise Problem(413,'Большой сектор: загрузите отдельную страницу или общий просмотр')
            suffix={'points':'.json','preview':'.preview.json','coverage':'.coverage.json'}.get(kind)
            if suffix is None:raise Problem(400,'Неизвестный вид сектора')
            path=self.root/'derived'/aid/(key+suffix)
            if not path.is_file():
                if kind=='preview':return (self.root/'derived'/aid/(key+'.json')).read_bytes()
                raise Problem(404,'Слой сектора не найден. Пересоберите модель.')
            return path.read_bytes()
    def assembly_overview(self,aid):
        identifier(aid)
        with self.lock:
            row=self.db.execute('SELECT data FROM assemblies WHERE id=?',(aid,)).fetchone()
            if not row:raise Problem(404,'Модель не найдена')
            path=self.root/'derived'/aid/'overview.json'
            if not path.is_file():raise Problem(404,'Общий просмотр отсутствует. Пересоберите модель.')
            return path.read_bytes()
    def assemblies(self,pid):
        self.project(pid)
        with self.lock:return [json.loads(r[0]) for r in self.db.execute('SELECT data FROM assemblies') if json.loads(r[0]).get('projectId')==pid]
    def job(self,jid):
        identifier(jid)
        with self.lock:
            row=self.db.execute('SELECT data FROM jobs WHERE id=?',(jid,)).fetchone()
            if not row:raise Problem(404,'Задание не найдено')
            return json.loads(row[0])
    def put_job(self,job):
        with self.lock,self.db:self.db.execute('INSERT OR REPLACE INTO jobs VALUES(?,?,?)',(job['id'],job['state'],dump(job)))
