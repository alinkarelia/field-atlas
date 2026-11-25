"""x0 adapter from the archive-analysis-v1 contract. No fabricated OCR fallback."""
import hashlib
import io
import json
import math
import os
import threading
import time
import urllib.request
import uuid
from PIL import Image,ImageOps
from .store import Problem,identifier

Image.MAX_IMAGE_PIXELS=30000000
ENDPOINT='https://byashek.ru/v1/archive/analyze'
OPTIONS={'metadata':False,'ocr':{'side':'front','languages':['rus','eng']},'nonperson_scene':False,'embedding':None}

def map_result(value,sha):
    if not isinstance(value,dict) or value.get('schema_version')!='archive-analysis-v1' or value.get('source_sha256')!=sha:
        raise ValueError('x0 вернул результат для другого источника')
    if any(value.get(k) is not None for k in ('metadata','scene','embedding')):raise ValueError('Неожиданный состав результата')
    ocr=value.get('ocr',{})
    if ocr.get('engine')!='tesseract' or ocr.get('side')!='front' or not isinstance(ocr.get('text'),str) or len(ocr['text'])>32000:
        raise ValueError('Некорректный результат OCR')
    spans=ocr.get('spans',[])
    if not isinstance(spans,list) or len(spans)>5000:raise ValueError('Некорректные области текста')
    lines=[]
    for span in spans:
        if not isinstance(span,dict) or not isinstance(span.get('text'),str) or len(span['text'])>500:raise ValueError('Некорректный фрагмент')
        b=span.get('box',{});v=[b.get(k) for k in ('x','y','w','h')];score=span.get('confidence')
        if not all(type(n) in (int,float) and math.isfinite(n) for n in v+[score]):raise ValueError('Некорректные координаты текста')
        x,y,w,h=v
        if not(0<=x<=1 and 0<=y<=1 and 0<w<=1 and 0<h<=1 and x+w<=1.000001 and y+h<=1.000001 and 0<=score<=1):raise ValueError('Некорректная область текста')
        lines.append({'text':span['text'],'box':b,'score':score,'needsReview':True})
    return {'text':ocr['text'],'lines':lines,'sourceHash':sha,'provider':'x0','engine':'tesseract','version':ocr.get('version'),'verified':False,'scoreIsProbability':False}

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs):return None

def recognize(raw,token):
    sha=hashlib.sha256(raw).hexdigest();boundary='FieldAtlas'+uuid.uuid4().hex
    parts=[f'--{boundary}\r\nContent-Disposition: form-data; name="options"\r\n\r\n'.encode()+json.dumps(OPTIONS).encode()+b'\r\n',
           f'--{boundary}\r\nContent-Disposition: form-data; name="source"; filename="inscription.png"\r\nContent-Type: image/png\r\n\r\n'.encode()+raw+b'\r\n',f'--{boundary}--\r\n'.encode()]
    req=urllib.request.Request(ENDPOINT,data=b''.join(parts),method='POST',headers={'Authorization':'Bearer '+token,'Content-Type':'multipart/form-data; boundary='+boundary,'Accept':'application/json','Accept-Encoding':'identity','X-Source-Sha256':sha})
    with urllib.request.build_opener(NoRedirect).open(req,timeout=145) as response:
        if response.headers.get_content_type()!='application/json':raise ValueError('x0 вернул неожиданный формат')
        body=response.read(4*1024**2+1)
        if len(body)>4*1024**2:raise ValueError('Ответ x0 слишком велик')
        return map_result(json.loads(body),sha)

def submit(store,payload):
    jid=identifier(payload.get('id'));pid=identifier(payload.get('projectId'));rid=identifier(payload.get('recordId'))
    project=store.project(pid)
    if project['type']!='cemetery':raise Problem(400,'Чтение плит доступно в проекте кладбища')
    file,asset=store.asset(identifier(payload.get('assetId')))
    if asset['project']!=pid:raise Problem(409,'Фотография относится к другому проекту')
    if asset['mime'] not in ('image/jpeg','image/png'):raise Problem(400,'Для x0 подготовьте JPEG или PNG')
    with store.lock:
        try:
            existing=store.job(jid)
            if existing['assetId']!=payload['assetId'] or existing['recordId']!=rid:raise Problem(409,'ID задания относится к другому источнику')
            return existing
        except Problem as err:
            if err.status!=404:raise
        token=os.environ.get('FIELD_X0_TOKEN')
        job={'id':jid,'projectId':pid,'recordId':rid,'assetId':payload['assetId'],'sourceHash':asset['sha'],'state':'queued' if token else 'blocked','createdAt':time.time()}
        if not token:job['error']='x0 пока не подключён к этой песочнице. Фотография сохранена; чтение можно выполнить после настройки сервера.'
        store.put_job(job)
    if token:threading.Thread(target=run,args=(store,job,file,token),daemon=True).start()
    return job

def run(store,job,file,token):
    try:
        job={**job,'state':'running'};store.put_job(job)
        with Image.open(file) as image:
            image=ImageOps.exif_transpose(image).convert('RGB');image.thumbnail((4000,4000));buf=io.BytesIO();image.save(buf,format='PNG');raw=buf.getvalue()
        if len(raw)>8*1024**2:raise ValueError('Нужен меньший фрагмент надписи для OCR')
        result=recognize(raw,token);result['originalSourceHash']=job['sourceHash'];result['transform']='exif-orient-and-fit-4000px'
        job={**job,'state':'succeeded','result':result};store.put_job(job)
    except Exception as err:
        # Do not expose request headers, credentials or provider response bodies.
        job={**job,'state':'failed','error':'Не удалось получить подтверждённый ответ x0. Исходник сохранён. Повторите чтение позднее.'};store.put_job(job)
