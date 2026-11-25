"""Loopback-only isolated workbench. Not a public production deployment."""
import argparse
import hashlib
import json
import mimetypes
import os
import sys
import threading
import time
import uuid
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlsplit,parse_qs

from .store import Store,Problem,identifier,dump
from .geometry import assemble,GeometryError

ROOT=Path(__file__).resolve().parents[1]
WEB=ROOT/'web'

def make_handler(store):
    from .identity import Identity
    from .assembly_jobs import AssemblyJobs
    if not hasattr(store,'assembler'):store.assembler=AssemblyJobs(store)
    identity=Identity(store)
    class Handler(BaseHTTPRequestHandler):
        server_version='FieldAtlas/0.4.0'
        def log_message(self,fmt,*args):pass
        def send(self,status,value,ctype='application/json; charset=utf-8'):
            data=dump(value).encode() if 'application/json' in ctype else value
            self.send_response(status);self.send_header('Content-Type',ctype);self.send_header('Content-Length',str(len(data)))
            self.send_header('Cache-Control','no-store' if self.path.startswith('/api/') else 'no-cache')
            self.send_header('X-Content-Type-Options','nosniff');self.send_header('Referrer-Policy','no-referrer')
            self.send_header('Content-Security-Policy',"default-src 'self'; img-src 'self' blob: data:; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self'; object-src 'none'; frame-ancestors 'none'")
            self.end_headers()
            if self.command!='HEAD':self.wfile.write(data)
        def body(self,binary=False):
            try:size=int(self.headers.get('Content-Length','0'))
            except ValueError:raise Problem(400,'Неверная длина запроса')
            if size<0 or size>(4*1024**2 if binary else 2*1024**2):raise Problem(413,'Запрос слишком велик')
            data=self.rfile.read(size)
            if len(data)!=size:raise Problem(400,'Неполный запрос')
            if binary:return data
            try:value=json.loads(data,parse_constant=lambda s:(_ for _ in ()).throw(ValueError(s)))
            except (ValueError,UnicodeError):raise Problem(400,'Некорректный JSON')
            if not isinstance(value,dict):raise Problem(400,'Ожидается объект')
            return value
        def gate(self):
            allowed={f'127.0.0.1:{self.server.server_port}',f'localhost:{self.server.server_port}'}
            host=self.headers.get('Host','')
            if host not in allowed:raise Problem(403,'Песочница доступна только локально')
            origin=self.headers.get('Origin')
            if origin and origin not in {'http://'+h for h in allowed}:raise Problem(403,'Чужой источник запроса')
        def route(self):
            self.gate();path=urlsplit(self.path).path;query=parse_qs(urlsplit(self.path).query)
            if self.command in ('GET','HEAD'):
                if path=='/api/health':return self.send(200,{'ok':True,'mode':'sandbox','version':'0.4.0','x0Configured':bool(os.environ.get('FIELD_X0_TOKEN')),'nativeCapture':False})
                if path=='/api/projects':return self.send(200,{'projects':store.projects()})
                if path=='/api/identity/candidates':return self.send(200,identity.candidates(query.get('recordId',[''])[0]))
                if path=='/api/identity/graph':return self.send(200,identity.export(query.get('projectId',[''])[0]))
                if path=='/api/records':return self.send(200,{'records':store.records(query.get('projectId',[''])[0])})
                if path=='/api/assemblies':return self.send(200,{'assemblies':store.assemblies(query.get('projectId',[''])[0])})
                if path.startswith('/api/assemblies/') and path.endswith('/overview'):return self.send(200,json.loads(store.assembly_overview(path.split('/')[3])))
                if path.startswith('/api/assemblies/') and '/tiles/' in path:
                    parts=path.split('/')
                    if len(parts)!=6:raise Problem(404,'Часть модели не найдена')
                    page=query.get('page',[None])[0]
                    if page is not None:
                        try:page=int(page)
                        except ValueError:raise Problem(400,'Неверная страница сектора')
                    return self.send(200,json.loads(store.assembly_tile(parts[3],parts[5],query.get('kind',['points'])[0],page)))
                if path.startswith('/api/uploads/'):return self.send(200,store.upload_status(path.rsplit('/',1)[-1]))
                if path.startswith('/api/jobs/'):return self.send(200,store.job(path.rsplit('/',1)[-1]))
                if path.startswith('/api/assets/'):
                    file,s=store.asset(path.rsplit('/',1)[-1]);return self.send(200,file.read_bytes(),s['mime'])
                if path.startswith('/api/'):raise Problem(404,'Маршрут не найден')
                relative=path.lstrip('/') or 'index.html';target=(WEB/relative).resolve()
                if not target.is_relative_to(WEB.resolve()) or not target.is_file():raise Problem(404,'Файл не найден')
                return self.send(200,target.read_bytes(),mimetypes.guess_type(target.name)[0] or 'application/octet-stream')
            if self.command=='POST':
                p=self.body()
                if path=='/api/projects':return self.send(200,store.save_project(p))
                if path=='/api/identity/import':return self.send(200,identity.import_people(p))
                if path=='/api/identity/decide':return self.send(200,identity.decide(p))
                if path=='/api/records':return self.send(200,store.save_record(p))
                if path=='/api/uploads':return self.send(200,store.init_upload(p))
                if path=='/api/assembly-jobs':return self.send(202,store.assembler.submit(p))
                if path.startswith('/api/assembly-jobs/') and path.endswith('/cancel'):return self.send(200,store.assembler.cancel(path.split('/')[3]))
                if path.startswith('/api/uploads/') and path.endswith('/complete'):return self.send(200,store.complete(path.split('/')[-2]))
                if path=='/api/assemble':
                    ids=p.get('chunks')
                    if not isinstance(ids,list) or not 1<=len(ids)<=40 or any(not isinstance(i,str) for i in ids) or len(set(ids))!=len(ids):raise Problem(400,'Нужно от 1 до 40 разных фрагментов')
                    chunks=[]
                    project=store.project(p.get('projectId'))
                    for cid in ids:
                        file,s=store.asset(cid)
                        if s['project']!=project['id']:raise Problem(409,'Фрагменты разных проектов нельзя объединять')
                        if s['mime']!='application/json' or s['size']>40*1024**2:raise Problem(400,'Ожидается JSON скана')
                        chunk=json.loads(file.read_bytes());chunk['id']=cid;chunks.append(chunk)
                    data=assemble(chunks);aid=hashlib.sha256(dump(sorted(ids)).encode()).hexdigest()[:24]
                    data.update(id=aid,projectId=project['id'],createdAt=time.time(),sourceIds=ids)
                    summary=store.put_assembly(aid,data);return self.send(200,summary)
                if path=='/api/ocr':
                    from .ocr import submit
                    return self.send(202,submit(store,p))
                raise Problem(404,'Маршрут не найден')
            if self.command=='PATCH' and path.startswith('/api/uploads/'):
                try:offset=int(self.headers.get('Upload-Offset','-1'))
                except ValueError:raise Problem(400,'Неверное смещение')
                return self.send(200,store.append(path.rsplit('/',1)[-1],offset,self.body(binary=True)))
            raise Problem(405,'Метод не поддерживается')
        def handle_request(self):
            try:self.route()
            except Problem as e:self.send(e.status,{'error':e.message,**e.details})
            except GeometryError as e:self.send(422,{'error':str(e)})
            except (json.JSONDecodeError,UnicodeError):self.send(400,{'error':'Некорректные данные файла'})
            except (BrokenPipeError,ConnectionResetError):pass
            except Exception as e:
                print(f'Internal error: {type(e).__name__}: {e}',file=sys.stderr,flush=True)
                self.send(500,{'error':'Не удалось выполнить операцию. Исходные данные сохранены.'})
        do_GET=handle_request;do_HEAD=handle_request;do_POST=handle_request;do_PATCH=handle_request
    return Handler

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--port',type=int,default=8879);parser.add_argument('--data',default=str(ROOT/'.runtime'))
    args=parser.parse_args();store=Store(args.data)
    server=ThreadingHTTPServer(('127.0.0.1',args.port),make_handler(store))
    print(f'FIELD_ATLAS http://127.0.0.1:{server.server_port} data={store.root}',flush=True)
    try:server.serve_forever()
    except KeyboardInterrupt:pass
    finally:server.server_close();store.close()

if __name__=='__main__':main()
