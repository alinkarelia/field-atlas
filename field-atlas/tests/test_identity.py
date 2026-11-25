import tempfile
import unittest
from server.store import Store,Problem
from server.identity import Identity,compare

class IdentityTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.store=Store(self.tmp.name);self.api=Identity(self.store)
        self.store.save_project({'id':'cemetery','type':'cemetery','title':'Test'})
        self.record={'id':'grave','projectId':'cemetery','kind':'grave','status':'draft','persons':[{'id':'slot1','name':'Ивановъ Пётр Иванович','birth':'1864','death':'1901'}],'transcription':'Ивановъ Пётр Иванович 1864–1901','photos':[]}
        self.version=0;self.save()
        self.people=[{'id':'one','name':'Иванов Петр Иванович','birth':'1864','death':'1901'},{'id':'two','name':'Иванов Петр Иванович','birth':'1894','death':'1955'}]
        self.import_people()
    def tearDown(self):self.store.close();self.tmp.cleanup()
    def save(self):
        self.version=self.store.save_record({'record':self.record,'mutationId':'m'+str(self.version),'baseVersion':self.version})['version']
    def import_people(self):return self.api.import_people({'schema':'field-people-v1','source':'archive','people':self.people})
    def candidate(self,person='one',slot=0):return next(c for c in self.api.candidates('grave')['groups'][slot]['candidates'] if c['person']['id']==person)
    def decide(self,c=None,state='confirmed',note='Сверил полное имя, даты и оригинал плиты'):
        c=c or self.candidate();return self.api.decide({'recordId':'grave','slot':c['slot'],'personKey':c['person']['key'],'token':c['token'],'state':state,'evidence':note})
    def test_old_spelling_and_dates_suggest_but_never_confirm(self):
        c=self.candidate();self.assertEqual(c['strength'],'review');self.assertIsNone(c['link']);self.assertEqual(self.api.links('cemetery'),[])
    def test_contradicting_namesake_cannot_be_confirmed(self):
        c=self.candidate('two');self.assertEqual(len(c['conflicts']),2)
        with self.assertRaises(Problem) as caught:self.decide(c)
        self.assertEqual(caught.exception.status,409)
    def test_surname_alone_is_weak(self):
        self.assertEqual(compare({'name':'Иванов'},self.people[0])['strength'],'weak')
    def test_uncertain_date_does_not_become_exact(self):
        c=compare({'name':'Иванов','birth':'18?4'},self.people[0]);self.assertEqual(c['score'],1)
    def test_known_day_contradiction_detected(self):
        self.assertIn('Различается дата рождения',compare({'name':'Иванов','birth':'12.03.1864'},{**self.people[0],'birth':'1864-03-13'})['conflicts'])
    def test_requires_evidence(self):
        with self.assertRaises(Problem):self.decide(note='да')
    def test_confirm_preserves_both_sources(self):
        before=self.api.people();link=self.decide();export=self.api.export('cemetery')
        self.assertEqual(link['relation'],'inscription_refers_to');self.assertEqual(before,self.api.people());self.assertFalse(export['mergePeople']);self.assertEqual(export['memorials'][0]['persons'],self.record['persons'])
    def test_decision_retry_has_one_audit_event(self):
        self.decide();self.decide();self.assertEqual(len(self.api.export('cemetery')['audit']),1)
    def test_record_change_rejects_stale_proposal(self):
        c=self.candidate();self.record['transcription']+=' уточнено';self.save()
        with self.assertRaises(Problem) as caught:self.decide(c)
        self.assertEqual(caught.exception.status,409)
    def test_new_reading_invalidates_existing_link(self):
        self.decide();self.record['persons'][0]['birth']='1865';self.save()
        self.assertEqual(self.api.links('cemetery')[0]['effectiveState'],'needs_review')
    def test_updated_site_person_invalidates_link(self):
        self.decide();self.people[0]['birth']='1865';self.import_people()
        self.assertEqual(self.api.links('cemetery')[0]['effectiveState'],'needs_review')
    def test_cosmetic_save_does_not_invalidate_evidence(self):
        self.decide();self.record['title']='Другой ориентир';self.save()
        self.assertEqual(self.api.links('cemetery')[0]['effectiveState'],'confirmed')
    def test_cannot_confirm_two_people_for_same_slot(self):
        self.decide();self.people.append({**self.people[0],'id':'duplicate'});self.import_people()
        with self.assertRaises(Problem):self.decide(self.candidate('duplicate'))
    def test_revoke_preserves_audit(self):
        self.decide();self.decide(state='revoked');export=self.api.export('cemetery');self.assertEqual(len(export['audit']),2);self.assertEqual(export['links'][0]['state'],'revoked')
    def test_multiple_people_on_one_memorial_remain_separate(self):
        self.record['persons'].append({'id':'slot2','name':'Смирнова Анна','birth':'1870','death':'1920'});self.save();self.people.append({'id':'anna','name':'Смирнова Анна','birth':'1870','death':'1920'});self.import_people()
        self.decide();self.decide(self.candidate('anna',1));self.assertEqual(len(self.api.links('cemetery')),2)
    def test_import_atomic_on_invalid_item(self):
        self.people.append({'id':'bad','name':'','url':'javascript:alert(1)'})
        with self.assertRaises(Problem):self.import_people()
        self.assertEqual(len(self.api.people()),2)
    def test_restart_keeps_decision_and_audit(self):
        self.decide();self.store.close();self.store=Store(self.tmp.name);self.api=Identity(self.store)
        self.assertEqual(self.api.links('cemetery')[0]['effectiveState'],'confirmed');self.assertEqual(len(self.api.export('cemetery')['audit']),1)
    def test_same_external_id_from_two_archives_is_distinct(self):
        self.api.import_people({'schema':'field-people-v1','source':'other','people':[self.people[0]]});self.assertEqual(len(self.api.people()),3)

if __name__=='__main__':unittest.main()
