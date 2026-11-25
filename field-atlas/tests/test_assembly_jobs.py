import hashlib,json,tempfile,time,unittest,threading
from unittest.mock import patch
from server.store import Store,Problem
from server.assembly_jobs import AssemblyJobs
from server.geometry import validate_chunk

class AssemblyJobsTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.store=Store(self.tmp.name);self.store.save_project({'id':'p','type':'land','title':'Test'});self.jobs=AssemblyJobs(self.store);self.store.assembler=self.jobs
    def tearDown(self):self.store.close();self.tmp.cleanup()
    def upload(self,identifier,points=None,frame='frame'):
        data=json.dumps({'schema':'field-scan-v1','id':identifier,'frameId':frame,'tracking':'normal','points':points or [[0,0,0,2],[1,0,0,2],[0,1,0,2]],'anchors':{}}).encode()
        self.store.init_upload({'id':identifier,'projectId':'p','size':len(data),'sha256':hashlib.sha256(data).hexdigest(),'mime':'application/json'});self.store.append(identifier,0,data);self.store.complete(identifier);return identifier
    def done(self,job):
        deadline=time.monotonic()+15
        while time.monotonic()<deadline:
            current=self.store.job(job['id'])
            if current['state'] in ('succeeded','failed','cancelled'):return current
            time.sleep(.015)
        self.fail('Assembly did not finish')
    def test_more_than_forty_chunks_assembled_and_retry_is_idempotent(self):
        ids=[self.upload('c'+str(i),[[i*10,0,0,2]]) for i in range(45)]
        job=self.done(self.jobs.submit({'projectId':'p','chunks':ids}));self.assertEqual(job['state'],'succeeded',job)
        result=self.store.assemblies('p')[0];self.assertEqual(len(result['registered']),45);self.assertEqual(sum(t['pointCount'] for t in result['tiles']),45)
        self.assertEqual(self.jobs.submit({'projectId':'p','chunks':list(reversed(ids))})['id'],job['id'])
        self.assertEqual(len(json.loads(self.store.assembly_overview(job['id']))['points']),45)
    def test_dense_sector_all_pages_and_coverage_are_available(self):
        points=[[x*.11,y*.11,z*.11,2] for x in range(30) for y in range(30) for z in range(13)]
        job=self.done(self.jobs.submit({'projectId':'p','chunks':[self.upload('dense',points)]}));self.assertEqual(job['state'],'succeeded',job)
        tile=self.store.assemblies('p')[0]['tiles'][0];self.assertEqual(tile['pages'],2)
        pages=[json.loads(self.store.assembly_tile(job['id'],tile['id'],page=i))['points'] for i in range(tile['pages'])]
        self.assertEqual(sum(map(len,pages)),len(points));self.assertLessEqual(max(map(len,pages)),10000)
        self.assertGreater(len(json.loads(self.store.assembly_tile(job['id'],tile['id'],'coverage'))['cells']),0)
        with self.assertRaises(Problem):self.store.assembly_tile(job['id'],tile['id'],page=2)
    def test_unrelated_frames_remain_pending(self):
        job=self.done(self.jobs.submit({'projectId':'p','chunks':[self.upload('a'),self.upload('b',frame='unrelated')]}));self.assertEqual(job['state'],'succeeded',job);self.assertEqual(len(self.store.assemblies('p')[0]['pending']),1)
    def test_cancel_never_publishes_partial_model_or_loses_source(self):
        cid=self.upload('a');entered=threading.Event();release=threading.Event()
        def slow(chunk):entered.set();release.wait(5);return validate_chunk(chunk)
        with patch('server.assembly_jobs.validate_chunk',side_effect=slow):
            job=self.jobs.submit({'projectId':'p','chunks':[cid]});self.assertTrue(entered.wait(3));self.jobs.cancel(job['id']);release.set();result=self.done(job)
        self.assertEqual(result['state'],'cancelled');self.assertEqual(self.store.assemblies('p'),[]);self.assertTrue(self.store.asset(cid)[0].is_file())
    def test_restart_turns_incomplete_job_into_retryable_failure(self):
        self.store.put_job({'id':'interrupted','type':'assembly','state':'running','sourceIds':[]});self.store.close();self.store=Store(self.tmp.name)
        self.assertEqual(self.store.job('interrupted')['state'],'failed')
    def test_queued_job_cancels_without_entering_memory_heavy_stage(self):
        a=self.upload('first');b=self.upload('queued');entered=threading.Event();release=threading.Event()
        def slow(chunk):entered.set();release.wait(5);return validate_chunk(chunk)
        with patch('server.assembly_jobs.validate_chunk',side_effect=slow):
            first=self.jobs.submit({'projectId':'p','chunks':[a]});self.assertTrue(entered.wait(3))
            queued=self.jobs.submit({'projectId':'p','chunks':[b]});self.assertEqual(self.store.job(queued['id'])['state'],'queued')
            self.jobs.cancel(queued['id']);self.assertEqual(self.done(queued)['state'],'cancelled');release.set();self.assertEqual(self.done(first)['state'],'succeeded')
        self.assertEqual(len(self.store.assemblies('p')),1)
