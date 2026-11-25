import copy
import tempfile
import unittest
from server.store import Store, Problem


class RoomPlanTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(self.tmp.name)
        self.store.save_project({'id':'house','type':'interior','title':'Испытательный дом'})
        self.doc = {'schema':'field-room-plan-v1','frameId':'room-test','rooms':[{'id':'r','name':'Комната','level':0,'walls':[{'id':'wall','start':[0,0],'end':[4,0],'height':3,'base':0,'confidence':2}],'openings':[{'id':'door','kind':'door','wallId':'wall','offset':1,'width':1,'height':2,'sill':0}],'floor':[[0,0],[4,0],[4,3],[0,3]]}]}
    def tearDown(self):
        self.store.close()
        self.tmp.cleanup()
    def save(self, doc=None, pid='house', kind='room'):
        return self.store.save_record({'mutationId':'test','baseVersion':0,'record':{'id':'room','projectId':pid,'kind':kind,'roomPlan':doc or self.doc}})
    def test_plan_survives_restart_with_opening_wall_and_coordinates(self):
        self.save()
        self.store.close()
        self.store = Store(self.tmp.name)
        self.assertEqual(self.store.records('house')[0]['roomPlan'], self.doc)
    def test_plan_cannot_enter_cemetery_or_facade_card(self):
        self.store.save_project({'id':'cemetery','type':'cemetery','title':'Испытание'})
        with self.assertRaises(Problem):self.save(pid='cemetery')
        with self.assertRaises(Problem):self.save(kind='facade')
        self.assertEqual(self.store.records('house'), [])
    def test_invalid_geometry_rejected_without_creating_record(self):
        mutations = [lambda r:r.update(walls=[]), lambda r:r['openings'][0].update(wallId='absent'), lambda r:r['openings'][0].update(width=8), lambda r:r.update(floor=[[0,0],[4,4],[0,4],[4,0]]), lambda r:r['walls'][0].update(profile=[[0,0],[4,0],[4,8]])]
        for mutate in mutations:
            doc=copy.deepcopy(self.doc);mutate(doc['rooms'][0])
            with self.assertRaises(Problem):self.save(doc)
            self.assertEqual(self.store.records('house'), [])
    def test_synthetic_measurements_cannot_be_passed_as_real(self):
        self.doc['synthetic']=True
        with self.assertRaises(Problem):self.save()
    def test_nonuniform_wall_keeps_source_profile(self):
        self.doc['rooms'][0]['walls'][0]['profile']=[[0,0],[4,0],[4,2.5],[0,3]]
        self.save()
        self.assertEqual(self.store.records('house')[0]['roomPlan'], self.doc)
