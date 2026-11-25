import copy,unittest
from server.room_plan import validate_ceiling,validate_plan

class CeilingTest(unittest.TestCase):
    def setUp(self):
        self.ceiling={'schema':'field-ceiling-v1','frameId':'separate','method':'manual-corners','reviewed':True,'floorPoint':[0,0,-1],'points':[[0,0,1.7],[4,0,1.7],[4,3,2.2],[0,3,2.2]]}
    def test_relative_heights_retained(self):self.assertEqual(validate_ceiling(self.ceiling),[2.7,2.7,3.2,3.2])
    def test_unreviewed_and_malformed_rejected(self):
        for patch in ({'reviewed':False},{'method':'automatic-truth'},{'floorPoint':[0,0]},{'points':[[0,0,2],[4,3,2],[0,3,2],[4,0,2]]},{'points':[[0,0,-2],[4,0,-2],[4,3,-2]]}):
            with self.assertRaises(ValueError):validate_ceiling(dict(self.ceiling,**patch))
    def test_manual_source_required(self):
        value={'schema':'field-ceiling-v1','method':'manual-height','reviewed':True,'source':'Лазерная рулетка','manualHeight':2.7}
        self.assertEqual(validate_ceiling(value),[2.7]);value['source']=''
        with self.assertRaises(ValueError):validate_ceiling(value)
    def test_room_cannot_flatten_sloping_ceiling(self):
        room={'id':'r','name':'Room','level':1,'walls':[{'id':'w','start':[0,0],'end':[4,0],'height':3,'base':0,'confidence':2}],'openings':[],'ceiling':self.ceiling}
        plan={'schema':'field-room-plan-v1','frameId':'plan','rooms':[room]};validate_plan(plan)
        room['ceilingHeight']=2.95
        with self.assertRaises(ValueError):validate_plan(plan)
    def test_synthetic_ceiling_cannot_be_real(self):
        room={'id':'r','name':'Room','walls':[{'id':'w','start':[0,0],'end':[4,0],'height':3,'base':0,'confidence':2}],'openings':[],'ceiling':dict(self.ceiling,synthetic=True)}
        with self.assertRaises(ValueError):validate_plan({'schema':'field-room-plan-v1','frameId':'p','rooms':[room]})
