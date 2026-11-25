"""Local maintenance CLI: consistent SQLite snapshot + verified immutable originals.

python -m server.backup create --data .runtime --output backup.atlas-server.zip
python -m server.backup verify backup.atlas-server.zip
python -m server.backup restore backup.atlas-server.zip --data NEW_DIRECTORY
"""
import argparse,hashlib,json,os,shutil,sqlite3,tempfile,time,zipfile
from pathlib import Path,PurePosixPath

BLOCK=1024*1024
def safe_name(name):
    if not isinstance(name,str):raise ValueError('Недопустимое имя файла в копии')
    path=PurePosixPath(name)
    if not isinstance(name,str) or not name or '\\' in name or ':' in name or path.is_absolute() or any(p in ('','.','..') for p in name.split('/')):
        raise ValueError('Недопустимое имя файла в копии')
    return name

def copy_hash(source,target,size):
    digest=hashlib.sha256();remaining=size
    while remaining:
        chunk=source.read(min(BLOCK,remaining))
        if not chunk:raise ValueError('Исходный файл обрезан')
        target.write(chunk);digest.update(chunk);remaining-=len(chunk)
    return digest.hexdigest()

def create(data,output):
    data=Path(data).resolve();output=Path(output).resolve()
    if not (data/'atlas.sqlite3').is_file():raise ValueError('База сервера не найдена')
    if output.exists():raise FileExistsError('Копия с таким именем уже существует')
    output.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='atlas-backup-',dir=output.parent) as tmp:
        temp=Path(tmp);database=temp/'atlas.sqlite3'
        source=sqlite3.connect((data/'atlas.sqlite3').as_uri()+'?mode=ro',uri=True)
        snapshot=sqlite3.connect(database);snapshot.row_factory=sqlite3.Row
        try:
            source.backup(snapshot)
            if snapshot.execute('PRAGMA integrity_check').fetchone()[0]!='ok':raise ValueError('Проверка базы не пройдена')
            uploads=[dict(row) for row in snapshot.execute('SELECT * FROM uploads')]
            assemblies=[json.loads(row[0]) for row in snapshot.execute('SELECT data FROM assemblies')]
        finally:source.close();snapshot.close()
        entries=[('atlas.sqlite3',database,database.stat().st_size,None)]
        for upload in uploads:
            name=safe_name('assets/'+upload['id']);file=data/name
            if not upload['complete'] and upload['offset']==0 and not file.exists():
                file=temp/('empty-'+upload['id']);file.touch()
            if file.is_symlink() or not file.is_file():raise ValueError('Отсутствует исходник '+name)
            entries.append((name,file,upload['size'] if upload['complete'] else upload['offset'],upload['sha'] if upload['complete'] else None))
        for assembly in assemblies:
            folder=data/safe_name('derived/'+assembly['id'])
            if not folder.is_dir() or folder.is_symlink():raise ValueError('Отсутствует собранная модель')
            for file in sorted(folder.iterdir()):
                if file.is_symlink() or not file.is_file():raise ValueError('Неизвестный файл модели')
                entries.append((safe_name(file.relative_to(data).as_posix()),file,file.stat().st_size,None))
        manifest={'schema':'field-server-backup-v1','createdAt':time.time(),'files':[],'note':'SQLite snapshot, original files, published models. Runtime spool and tokens excluded.'}
        archive=temp/'backup.zip'
        with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=3,allowZip64=True) as z:
            for name,file,size,expected in entries:
                with file.open('rb') as src,z.open(name,'w',force_zip64=True) as dest:sha=copy_hash(src,dest,size)
                if expected and expected!=sha:raise ValueError('Контрольная сумма оригинала не совпала: '+name)
                manifest['files'].append({'name':name,'size':size,'sha256':sha})
            z.writestr('manifest.json',json.dumps(manifest,ensure_ascii=False,allow_nan=False))
        verify(archive)
        # Same filesystem, atomic publication and no overwrite if another backup wins.
        os.link(archive,output)
    return manifest

def inspect(z):
    info=z.getinfo('manifest.json')
    if info.file_size>32*1024**2:raise ValueError('Слишком большой реестр копии')
    manifest=json.loads(z.read(info))
    if not isinstance(manifest,dict) or manifest.get('schema')!='field-server-backup-v1' or not isinstance(manifest.get('files'),list) or len(manifest['files'])>1000000:raise ValueError('Неизвестный формат копии сервера')
    expected={'manifest.json'}
    for row in manifest['files']:
        if not isinstance(row,dict):raise ValueError('Некорректная запись реестра')
        name=safe_name(row['name'])
        if name in expected or type(row.get('size')) is not int or row['size']<0 or not isinstance(row.get('sha256'),str) or len(row['sha256'])!=64:raise ValueError('Некорректный реестр файлов')
        expected.add(name)
        item=z.getinfo(name)
        if item.file_size!=row['size'] or item.is_dir() or (item.external_attr>>16)&0o170000==0o120000:raise ValueError('Размер или тип файла не соответствует реестру')
    names=z.namelist()
    if len(names)!=len(expected) or set(names)!=expected or 'atlas.sqlite3' not in expected:raise ValueError('Состав копии не соответствует реестру')
    return manifest

def verify(file,destination=None):
    with zipfile.ZipFile(file,'r') as z:
        manifest=inspect(z)
        for row in manifest['files']:
            target=None
            if destination:
                target=(Path(destination)/row['name']).resolve()
                if not target.is_relative_to(Path(destination).resolve()):raise ValueError('Файл вне папки восстановления')
                target.parent.mkdir(parents=True,exist_ok=True)
            with z.open(row['name']) as src, (target.open('xb') if target else open(os.devnull,'wb')) as dest:
                digest=copy_hash(src,dest,row['size'])
                if target:dest.flush();os.fsync(dest.fileno())
            if digest!=row['sha256']:raise ValueError('Контрольная сумма не совпала: '+row['name'])
    return manifest

def restore(file,data):
    target=Path(data).resolve()
    if target.exists():raise FileExistsError('Восстанавливайте в новую папку. Действующие данные не перезаписываются.')
    target.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='atlas-restore-',dir=target.parent) as tmp:
        stage=Path(tmp)/'data';stage.mkdir()
        manifest=verify(file,stage)
        db=sqlite3.connect((stage/'atlas.sqlite3').as_uri()+'?mode=ro',uri=True)
        try:
            if db.execute('PRAGMA integrity_check').fetchone()[0]!='ok':raise ValueError('Проверка восстановленной базы не пройдена')
            for identifier,size,offset,complete in db.execute('SELECT id,size,offset,complete FROM uploads'):
                source=stage/safe_name('assets/'+identifier)
                if not source.is_file() or source.stat().st_size!=(size if complete else offset):raise ValueError('Восстановленный исходник отсутствует или обрезан')
        finally:db.close()
        stage.rename(target)
    return manifest

def main():
    parser=argparse.ArgumentParser(description='Проверяемая резервная копия сервера Полевого атласа');sub=parser.add_subparsers(dest='command',required=True)
    p=sub.add_parser('create');p.add_argument('--data',required=True);p.add_argument('--output',required=True)
    p=sub.add_parser('verify');p.add_argument('file')
    p=sub.add_parser('restore');p.add_argument('file');p.add_argument('--data',required=True)
    args=parser.parse_args()
    try:
        result=create(args.data,args.output) if args.command=='create' else verify(args.file) if args.command=='verify' else restore(args.file,args.data)
        print(json.dumps({'ok':True,'files':len(result['files']),'bytes':sum(r['size'] for r in result['files'])},ensure_ascii=False))
    except (OSError,ValueError,KeyError,sqlite3.Error,zipfile.BadZipFile) as error:parser.exit(1,str(error)+'\n')

if __name__=='__main__':main()
