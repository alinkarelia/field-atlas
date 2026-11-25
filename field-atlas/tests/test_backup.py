import hashlib,json,sqlite3,tempfile,unittest,zipfile
from pathlib import Path
from server.store import Store
from server.backup import create,verify,restore
from server.identity import Identity
from server.geometry import assemble

class ServerBackupTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);self.store=Store(self.root/'live');self.store.save_project({'id':'p','title':'Test','type':'cemetery'});self.file=self.root/'backup.zip'
        self.body=b'original data, not a thumbnail';self.store.init_upload({'id':'original','projectId':'p','size':len(self.body),'sha256':hashlib.sha256(self.body).hexdigest(),'mime':'image/png'});self.store.append('original',0,self.body);self.store.complete('original')
        with self.store.db:self.store.db.execute('CREATE TABLE graph_history(id TEXT PRIMARY KEY,data TEXT)');self.store.db.execute('INSERT INTO graph_history VALUES(?,?)',('decision','both sources retained'))
    def tearDown(self):self.store.close();self.tmp.cleanup()
    def test_live_sqlite_snapshot_restores_original_and_all_graph_tables(self):
        create(self.store.root,self.file);self.store.save_project({'id':'later','title':'After snapshot','type':'land'});restore(self.file,self.root/'restored')
        restored=Store(self.root/'restored')
        try:
            self.assertEqual(len(restored.projects()),1);self.assertEqual(restored.asset('original')[0].read_bytes(),self.body)
            self.assertEqual(restored.db.execute('SELECT data FROM graph_history').fetchone()[0],'both sources retained')
        finally:restored.close()
    def test_partial_upload_restores_only_committed_prefix_and_can_resume(self):
        data=b'new-upload';self.store.init_upload({'id':'partial','projectId':'p','size':len(data),'sha256':hashlib.sha256(data).hexdigest(),'mime':'image/png'});self.store.append('partial',0,data[:4]);create(self.store.root,self.file);self.store.append('partial',4,data[4:]);restore(self.file,self.root/'resumed');restored=Store(self.root/'resumed')
        try:restored.append('partial',4,data[4:]);restored.complete('partial');self.assertEqual(restored.asset('partial')[0].read_bytes(),data)
        finally:restored.close()
    def test_damaged_archive_never_publishes_destination(self):
        create(self.store.root,self.file)
        with zipfile.ZipFile(self.file) as z:entries={name:z.read(name) for name in z.namelist()}
        entries['assets/original']=b'X'+entries['assets/original'][1:]
        with zipfile.ZipFile(self.root/'damaged.zip','w') as z:
            for name,value in entries.items():z.writestr(name,value)
        with self.assertRaises(ValueError):restore(self.root/'damaged.zip',self.root/'bad')
        self.assertFalse((self.root/'bad').exists());self.assertEqual(self.store.asset('original')[0].read_bytes(),self.body)
    def test_existing_destination_and_existing_backup_never_overwritten(self):
        create(self.store.root,self.file);before=self.file.read_bytes()
        with self.assertRaises(FileExistsError):create(self.store.root,self.file)
        with self.assertRaises(FileExistsError):restore(self.file,self.store.root)
        self.assertEqual(self.file.read_bytes(),before)
    def test_path_traversal_in_manifest_rejected(self):
        manifest={'schema':'field-server-backup-v1','files':[{'name':'../outside','size':1,'sha256':hashlib.sha256(b'x').hexdigest()}]}
        with zipfile.ZipFile(self.file,'w') as z:z.writestr('manifest.json',json.dumps(manifest));z.writestr('../outside',b'x')
        with self.assertRaises(ValueError):restore(self.file,self.root/'bad')
        self.assertFalse((self.root/'outside').exists())
    def test_actual_identity_decision_and_model_survive_restore(self):
        identity=Identity(self.store)
        record={'id':'grave','projectId':'p','kind':'grave','status':'draft','persons':[{'id':'person-slot','name':'Иванов Петр Иванович','birth':'1864','death':'1901'}]}
        self.store.save_record({'record':record,'mutationId':'m','baseVersion':0})
        identity.import_people({'schema':'field-people-v1','source':'archive','people':[{'id':'person','name':'Иванов Петр Иванович','birth':'1864','death':'1901'}]})
        c=identity.candidates('grave')['groups'][0]['candidates'][0]
        identity.decide({'recordId':'grave','slot':c['slot'],'personKey':c['person']['key'],'token':c['token'],'state':'confirmed','evidence':'Сверено с исходником в испытании'})
        original=identity.export('p')
        cloud=assemble([{'id':'a','schema':'field-scan-v1','frameId':'f','tracking':'normal','points':[[0,0,0,2],[1,0,0,2],[0,1,0,2]],'anchors':{}}]);cloud.update(id='model',projectId='p');self.store.put_assembly('model',cloud)
        create(self.store.root,self.file);restore(self.file,self.root/'full');restored=Store(self.root/'full')
        try:
            graph=Identity(restored).export('p');self.assertEqual(graph['links'],original['links']);self.assertEqual(graph['audit'],original['audit']);self.assertEqual(graph['people'],original['people'])
            self.assertEqual(json.loads(restored.assembly_tile('model','0_0'))['points'],json.loads(self.store.assembly_tile('model','0_0'))['points'])
        finally:restored.close()
    def test_initialized_but_empty_upload_restores_as_retryable(self):
        self.store.init_upload({'id':'empty','projectId':'p','size':3,'sha256':hashlib.sha256(b'abc').hexdigest(),'mime':'image/png'});create(self.store.root,self.file);restore(self.file,self.root/'new')
        restored=Store(self.root/'new')
        try:restored.append('empty',0,b'abc');self.assertEqual(restored.complete('empty')['complete'],1)
        finally:restored.close()
