import hashlib,json,tempfile,unittest,threading,urllib.request,urllib.error
from http.server import ThreadingHTTPServer
from pathlib import Path
import numpy as np
from server.store import Store,Problem
from server.geometry import register,assemble,GeometryError
from server.app import make_handler
from server.ocr import map_result,submit

def project(pid='p',kind='cemetery'):return {'id':pid,'type':kind,'title':'Учебный проект'}
def record(pid='p',rid='grave'):return {'id':rid,'projectId':pid,'kind':'grave','status':'draft','point':[0,0],'photos':[]}
def chunk(cid='a',frame='f',anchors=None):return {'id':cid,'schema':'field-scan-v1','frameId':frame,'tracking':'normal','points':[[0,0,0,2],[1,0,0,2],[0,1,0,1]],'anchors':anchors or {}}

class StoreTest(unittest.TestCase):
    def setUp(self):self.tmp=tempfile.TemporaryDirectory();self.s=Store(self.tmp.name);self.s.save_project(project())
    def tearDown(self):self.s.close();self.tmp.cleanup()
    def payload(self,base=0,mid='m'):return {'record':record(),'baseVersion':base,'mutationId':mid}
    def upload(self,data=b'abcdef',uid='asset',pid='p',mime='application/octet-stream'):
        self.s.init_upload({'id':uid,'projectId':pid,'size':len(data),'sha256':hashlib.sha256(data).hexdigest(),'mime':mime});return data
    def test_record_durable_restart(self):
        self.s.save_record(self.payload());self.s.close();self.s=Store(self.tmp.name);self.assertEqual(self.s.records('p')[0]['serverVersion'],1)
    def test_idempotent_ack_retry(self):
        a=self.s.save_record(self.payload());self.assertEqual(a,self.s.save_record(self.payload()));self.assertEqual(len(self.s.records('p')),1)
    def test_changed_payload_same_request_rejected(self):
        self.s.save_record(self.payload());p=self.payload();p['record']['title']='changed'
        with self.assertRaises(Problem):self.s.save_record(p)
    def test_conflict_preserves_first(self):
        self.s.save_record(self.payload())
        with self.assertRaises(Problem) as ctx:self.s.save_record(self.payload(mid='m2'))
        self.assertEqual(ctx.exception.status,409);self.assertEqual(self.s.records('p')[0]['serverVersion'],1)
    def test_project_isolation(self):
        self.s.save_project(project('house','interior'));self.s.save_record(self.payload());self.assertEqual(self.s.records('house'),[])
        p=self.payload(mid='m2');p['record']['projectId']='house'
        with self.assertRaises(Problem):self.s.save_record(p)
    def test_object_cannot_change_project(self):
        self.s.save_project(project('q'));self.s.save_record(self.payload());p=self.payload(1,'m2');p['record']['projectId']='q'
        with self.assertRaises(Problem):self.s.save_record(p)
    def test_upload_resume_after_restart(self):
        self.upload();self.s.append('asset',0,b'abc');self.s.close();self.s=Store(self.tmp.name)
        self.assertEqual(self.s.upload_status('asset')['offset'],3);self.s.append('asset',3,b'def');self.assertEqual(self.s.complete('asset')['complete'],1)
    def test_upload_wrong_offset(self):
        self.upload();self.s.append('asset',0,b'abc')
        with self.assertRaises(Problem) as ctx:self.s.append('asset',0,b'abc')
        self.assertEqual(ctx.exception.details['offset'],3)
    def test_incomplete_never_ready(self):
        self.upload();self.s.append('asset',0,b'abc')
        with self.assertRaises(Problem):self.s.complete('asset')
    def test_corruption_never_ready(self):
        self.upload();self.s.append('asset',0,b'xxxxxx')
        with self.assertRaises(Problem) as ctx:self.s.complete('asset')
        self.assertEqual(ctx.exception.status,422)
    def test_crash_uncommitted_tail_trimmed(self):
        self.upload();self.s.append('asset',0,b'abc');(self.s.assets/'asset').write_bytes(b'abcWRONG');self.s.append('asset',3,b'def');self.assertEqual(self.s.complete('asset')['complete'],1)
    def test_upload_id_cannot_move_projects(self):
        self.upload();self.s.save_project(project('q'))
        with self.assertRaises(Problem):self.upload(pid='q')
    def test_path_traversal_rejected(self):
        with self.assertRaises(Problem):self.upload(uid='../outside')
    def test_ocr_blocked_has_no_fake_text(self):
        import os
        from unittest.mock import patch
        self.upload(b'not-needed-for-disabled-provider',mime='image/png');self.s.append('asset',0,b'not-needed-for-disabled-provider');self.s.complete('asset')
        with patch.dict(os.environ,{},clear=True):job=submit(self.s,{'id':'job','projectId':'p','recordId':'g','assetId':'asset'})
        self.assertEqual(job['state'],'blocked');self.assertNotIn('result',job)

class GeometryTest(unittest.TestCase):
    def test_small_final_fragment_is_preserved(self):
        c=chunk();c['points']=c['points'][:1];result=assemble([c]);self.assertEqual(sum(map(len,result['tiles'].values())),1)
    def test_known_rotation_translation_recovered(self):
        a={'A':[0,0,0],'B':[3,0,0],'C':[0,4,0],'D':[0,0,2]};r=np.array([[0,-1,0],[1,0,0],[0,0,1]]);t=np.array([5,-3,2]);b={k:(r@np.array(p)+t).tolist() for k,p in a.items()};rr,tt,error=register(a,b);np.testing.assert_allclose(rr,r,atol=1e-12);np.testing.assert_allclose(tt,t,atol=1e-12);self.assertLess(error,1e-12)
    def test_collinear_controls_rejected(self):
        a={'A':[0,0,0],'B':[1,0,0],'C':[2,0,0]}
        with self.assertRaises(GeometryError):register(a,a)
    def test_bad_controls_rejected(self):
        a={'A':[0,0,0],'B':[1,0,0],'C':[0,1,0]};b={**a,'C':[9,1,0]}
        with self.assertRaises(GeometryError):register(a,b)
    def test_unrelated_frames_not_silently_joined(self):
        result=assemble([chunk(),chunk('b','another')]);self.assertEqual(result['registered'],['a']);self.assertEqual(len(result['pending']),1)
    def test_matching_frames_join_and_deduplicate(self):
        result=assemble([chunk(),chunk('b')]);self.assertEqual(len(result['registered']),2);self.assertEqual(sum(map(len,result['tiles'].values())),3)
    def test_low_quality_frame_not_accepted(self):
        b=chunk('b');b['tracking']='limited';self.assertEqual(len(assemble([chunk(),b])['pending']),1)
    def test_bad_number_rejected(self):
        b=chunk();b['points'][0][0]=float('nan')
        with self.assertRaises(GeometryError):assemble([b])
    def test_coverage_never_fills_holes(self):
        result=assemble([chunk()]);self.assertEqual(len(result['coverage']),3)

class OCRTest(unittest.TestCase):
    def test_interrupted_job_becomes_retryable_after_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            store=Store(directory);store.put_job({'id':'ocr','state':'running','assetId':'photo'});store.close();store=Store(directory)
            try:self.assertEqual(store.job('ocr')['state'],'failed');self.assertEqual(store.job('ocr')['assetId'],'photo')
            finally:store.close()
    def result(self):return {'schema_version':'archive-analysis-v1','source_sha256':'a','ocr':{'engine':'tesseract','side':'front','text':'ИВАНОВ','spans':[{'text':'ИВАНОВ','box':{'x':0,'y':0,'w':1,'h':.2},'confidence':.8}]}}
    def test_valid_text_always_needs_review(self):self.assertFalse(map_result(self.result(),'a')['verified'])
    def test_mismatched_source_rejected(self):
        with self.assertRaises(ValueError):map_result(self.result(),'b')
    def test_invalid_region_rejected(self):
        r=self.result();r['ocr']['spans'][0]['box']['x']=2
        with self.assertRaises(ValueError):map_result(r,'a')

class HTTPTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.s=Store(self.tmp.name);self.server=ThreadingHTTPServer(('127.0.0.1',0),make_handler(self.s));self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start();self.base=f'http://127.0.0.1:{self.server.server_port}'
    def tearDown(self):self.server.shutdown();self.thread.join();self.server.server_close();self.s.close();self.tmp.cleanup()
    def test_cross_origin_write_blocked(self):
        req=urllib.request.Request(self.base+'/api/projects',data=b'{}',headers={'Origin':'https://other.example','Content-Type':'application/json'})
        with self.assertRaises(urllib.error.HTTPError) as c:urllib.request.urlopen(req)
        self.assertEqual(c.exception.code,403)
    def test_health(self):
        with urllib.request.urlopen(self.base+'/api/health') as r:self.assertEqual(json.load(r)['mode'],'sandbox')
    def test_unknown_path(self):
        with self.assertRaises(urllib.error.HTTPError) as c:urllib.request.urlopen(self.base+'/api/nope')
        self.assertEqual(c.exception.code,404)
    def test_tiles_return_separately_from_manifest(self):
        self.s.save_project(project());result=assemble([chunk()]);result.update(id='assembled',projectId='p')
        summary=self.s.put_assembly('assembled',result)
        self.assertIsInstance(summary['tiles'],list);self.assertNotIn('points',summary['tiles'][0])
        with urllib.request.urlopen(self.base+summary['tiles'][0]['url']) as response:
            tile=json.load(response);self.assertEqual(tile['schema'],'field-tile-v1');self.assertTrue(tile['points'])
    def test_assembly_rejects_cross_project_chunks(self):
        self.s.save_project(project());self.s.save_project(project('q'))
        for pid in ('p','q'):
            data=json.dumps(chunk(pid)).encode();self.s.init_upload({'id':pid,'projectId':pid,'sha256':hashlib.sha256(data).hexdigest(),'size':len(data),'mime':'application/json'});self.s.append(pid,0,data);self.s.complete(pid)
        request=urllib.request.Request(self.base+'/api/assemble',data=json.dumps({'projectId':'p','chunks':['p','q']}).encode(),headers={'Content-Type':'application/json'})
        with self.assertRaises(urllib.error.HTTPError) as caught:urllib.request.urlopen(request)
        self.assertEqual(caught.exception.code,409)

if __name__=='__main__':unittest.main(verbosity=2)
