"""Bounded-memory assembly: immutable inputs, disk voxels and independently readable tiles."""
import hashlib
import json
import math
import sqlite3
import shutil
import threading
import time
import uuid
from pathlib import Path
import numpy as np
from .geometry import validate_chunk, align_chunks
from .store import Problem, dump

class Cancelled(Exception):
    pass

class AssemblyJobs:
    def __init__(self, store):
        self.store=store;self.lock=threading.RLock();self.running={};self.slot=threading.BoundedSemaphore(1)
    def submit(self, payload):
        pid=payload.get('projectId');self.store.project(pid);ids=payload.get('chunks')
        if not isinstance(ids,list) or not 1<=len(ids)<=2000 or any(not isinstance(i,str) for i in ids) or len(set(ids))!=len(ids):
            raise Problem(400,'Выберите от 1 до 2000 разных фрагментов')
        ids=sorted(ids)
        for cid in ids:
            _,entry=self.store.asset(cid)
            if entry['project']!=pid:raise Problem(409,'Фрагменты разных проектов')
            if entry['mime']!='application/json' or entry['size']>40*1024**2:raise Problem(400,'Ожидаются отдельные JSON-фрагменты до 40 МБ')
        jid='assembly-'+hashlib.sha256(dump([pid,ids,'stream-v1']).encode()).hexdigest()[:24]
        with self.lock:
            try:old=self.store.job(jid)
            except Problem:old=None
            if jid in self.running or old and old['state']=='succeeded':return old
            if len(self.running)>=64:raise Problem(429,'Очередь сборки заполнена. Дождитесь завершения текущих проектов.')
            job={'id':jid,'type':'assembly','projectId':pid,'sourceIds':ids,'state':'queued','progress':0,'message':'В очереди','createdAt':time.time()}
            self.store.put_job(job);event=threading.Event();thread=threading.Thread(target=self.work,args=(job,event),daemon=True,name=jid)
            self.running[jid]=(event,thread);thread.start();return job
    def cancel(self, jid):
        with self.lock:
            job=self.store.job(jid)
            if job.get('type')!='assembly':raise Problem(400,'Это не задание сборки')
            if jid in self.running:
                self.running[jid][0].set();job.update(state='cancelling',message='Завершаем текущую операцию');self.store.put_job(job)
            return job
    def close(self):
        with self.lock:active=list(self.running.values())
        for event,_ in active:event.set()
        for _,thread in active:thread.join(timeout=10)
    def work(self, job, stop):
        store=self.store;jid=job['id'];spool=None;stage=None;acquired=False
        def checkpoint():
            if stop.is_set():raise Cancelled()
        def update(progress,message):
            checkpoint();job.update(state='running',progress=progress,message=message);store.put_job(job)
        def read(cid):
            file,_=store.asset(cid);data=json.loads(file.read_bytes());data['id']=cid;validate_chunk(data);return data
        try:
            while not self.slot.acquire(timeout=.1):checkpoint()
            acquired=True;checkpoint()
            headers=[];ids=job['sourceIds'];count=len(ids)
            for i,cid in enumerate(ids):
                update(.15*i/count,f'Проверяем исходники: {i+1} из {count}')
                chunk=read(cid);headers.append({k:v for k,v in chunk.items() if k!='points'})
            chunk=None
            reference,accepted,pending,reasons=align_chunks(headers)
            stage=store.root/'jobs'/jid/uuid.uuid4().hex;stage.mkdir(parents=True)
            spool=sqlite3.connect(stage/'voxels.sqlite3');spool.execute('PRAGMA cache_size=-8192');spool.execute('PRAGMA temp_store=FILE');spool.create_function('cell',1,lambda v:math.floor(v/.5),deterministic=True)
            spool.execute('CREATE TABLE voxels(x INTEGER,y INTEGER,z INTEGER,tx INTEGER,ty INTEGER,px REAL,py REAL,pz REAL,q INTEGER,PRIMARY KEY(x,y,z)) WITHOUT ROWID')
            transforms=[]
            for index,(header,r,t,error) in enumerate(accepted):
                update(.15+.6*index/len(accepted),f'Совмещаем части: {index+1} из {len(accepted)}')
                chunk=read(header['id']);a=np.asarray(chunk['points'],dtype=float);a=a[a[:,3]>=1];q=a[:,:3]@r.T+t;keys=np.floor(q/.1).astype(np.int64)
                for start in range(0,len(a),5000):
                    checkpoint()
                    rows=((int(k[0]),int(k[1]),int(k[2]),math.floor(p[0]/10),math.floor(p[1]/10),round(float(p[0]),4),round(float(p[1]),4),round(float(p[2]),4),int(source[3])) for k,p,source in zip(keys[start:start+5000],q[start:start+5000],a[start:start+5000]))
                    spool.executemany('INSERT INTO voxels VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(x,y,z) DO UPDATE SET px=excluded.px,py=excluded.py,pz=excluded.pz,q=excluded.q WHERE excluded.q>voxels.q',rows)
                spool.commit();transforms.append({'id':header['id'],'frameId':header['frameId'],'rotation':r.tolist(),'translation':t.tolist(),'controlRMSE':error})
                chunk=a=q=keys=None
            update(.76,'Подготавливаем пространственные сектора')
            spool.execute('CREATE INDEX regions ON voxels(tx,ty)');tiles=spool.execute('SELECT tx,ty,count(*) FROM voxels GROUP BY tx,ty ORDER BY tx,ty').fetchall()
            if len(tiles)>20000:raise ValueError('Больше 20000 секторов. Разделите проект на экспедиции.')
            output=stage/'tiles';output.mkdir();overview=[];coverage=[];coverage_count=0;index=[]
            for i,(tx,ty,n) in enumerate(tiles):
                update(.78+.2*i/max(1,len(tiles)),f'Сохраняем секторы: {i+1} из {len(tiles)}');key=f'{tx}_{ty}';preview=[];bounds=[math.inf]*3+[-math.inf]*3
                stride=max(1,math.ceil(n/1200));overview_stride=max(1,math.ceil(n/max(1,30000//max(1,len(tiles)))));page_points=[];page_number=0
                def write_page():
                    (output/(key+f'.page-{page_number}.json')).write_text(dump({'schema':'field-tile-v1','frameId':reference['frameId'],'points':page_points}),encoding='utf-8')
                with (output/(key+'.json')).open('w',encoding='utf-8') as file:
                    file.write('{"schema":"field-tile-v1","frameId":'+dump(reference['frameId'])+',"points":[')
                    for j,row in enumerate(spool.execute('SELECT px,py,pz,q FROM voxels WHERE tx=? AND ty=? ORDER BY x,y,z',(tx,ty))):
                        if j%5000==0:checkpoint()
                        point=list(row);file.write((',' if j else '')+dump(point))
                        page_points.append(point)
                        if len(page_points)==10000:write_page();page_points=[];page_number+=1
                        for axis in range(3):bounds[axis]=min(bounds[axis],point[axis]);bounds[axis+3]=max(bounds[axis+3],point[axis])
                        if j%stride==0:preview.append(point)
                        if j%overview_stride==0:overview.append(point)
                    file.write(']}')
                if page_points:write_page();page_number+=1
                cell_count=0
                with (output/(key+'.coverage.json')).open('w',encoding='utf-8') as file:
                    file.write('{"schema":"field-coverage-v1","frameId":'+dump(reference['frameId'])+',"cells":[')
                    for cx,cy,cz,quality in spool.execute('SELECT cell(px),cell(py),cell(pz),max(q) FROM voxels WHERE tx=? AND ty=? GROUP BY cell(px),cell(py),cell(pz)',(tx,ty)):
                        if cell_count%5000==0:checkpoint()
                        item={'x':cx*.5,'y':cy*.5,'z':cz*.5,'quality':quality,'cell':.5};file.write((',' if cell_count else '')+dump(item));cell_count+=1
                        if len(coverage)<50000:coverage.append(item)
                    file.write(']}')
                coverage_count+=cell_count
                (output/(key+'.preview.json')).write_text(dump({'schema':'field-tile-v1','frameId':reference['frameId'],'points':preview}),encoding='utf-8')
                index.append({'id':key,'pointCount':n,'bounds':bounds,'coverageCells':cell_count,'pages':page_number,'pageSize':10000,'url':f'/api/assemblies/{jid}/tiles/{key}'})
            (output/'overview.json').write_text(dump({'schema':'field-tile-v1','frameId':reference['frameId'],'points':overview}),encoding='utf-8')
            summary={'id':jid,'schema':'field-assembly-v1','projectId':job['projectId'],'referenceFrame':reference['frameId'],'registered':[c['id'] for c,*_ in accepted],
                     'pending':[{'id':c['id'],'reason':reasons.get(c['id'],'Не удалось связать')} for c in pending],'transforms':transforms,'sourceIds':ids,'tiles':index,
                     'coverage':coverage,'coveragePreviewTruncated':coverage_count>50000,'coverageCellCount':coverage_count,'overviewURL':f'/api/assemblies/{jid}/overview',
                     'method':'shared-frame-or-named-controls','createdAt':time.time(),'geodeticAccuracy':None}
            checkpoint();target=store.root/'derived'/jid;target.mkdir(parents=True,exist_ok=True)
            for file in output.iterdir():file.replace(target/file.name)
            with store.lock,store.db:store.db.execute('INSERT OR REPLACE INTO assemblies VALUES(?,?)',(jid,dump(summary)))
            job.update(state='succeeded',progress=1,message='Сборка готова',assemblyId=jid);store.put_job(job)
        except Cancelled:
            job.update(state='cancelled',message='Сборка отменена. Исходники сохранены.');store.put_job(job)
        except Exception as error:
            job.update(state='failed',error=str(error),message='Сборка остановлена. Исходники сохранены.');store.put_job(job)
        finally:
            if spool:spool.close()
            if stage is not None:
                resolved=stage.resolve();allowed=(store.root/'jobs').resolve()
                if resolved.is_relative_to(allowed) and resolved!=allowed:shutil.rmtree(resolved,ignore_errors=True)
            if acquired:self.slot.release()
            with self.lock:self.running.pop(jid,None)
