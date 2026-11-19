import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from tome_mvp.wasm.session_store import SessionStore,ROOT

class FrozenValidatorIdentityTest(unittest.TestCase):
 def test_frozen_helper_must_match_code_and_identity(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp);public=root/'public';public.mkdir()
   host=(ROOT/'scripts/tome_session_host.mjs').read_bytes();helper=(ROOT/'scripts/tome_validate_operations.mjs').read_bytes()
   (root/'validator.mjs').write_bytes(host);(root/'tome_validate_operations.mjs').write_bytes(helper)
   identity={'inputs':{'host_validator_sha256':hashlib.sha256(host).hexdigest(),'host_validator_operations_sha256':hashlib.sha256(helper).hexdigest()}}
   (root/'identity.json').write_text(json.dumps(identity),encoding='utf8')
   store=SessionStore(root/'db.sqlite',public,resident_validation=True)
   self.assertTrue(store._resident_compatible())
   (root/'tome_validate_operations.mjs').write_bytes(helper+b' ')
   self.assertFalse(store._resident_compatible())
   (root/'tome_validate_operations.mjs').write_bytes(helper)
   identity['inputs']['host_validator_operations_sha256']='0'*64
   (root/'identity.json').write_text(json.dumps(identity),encoding='utf8')
   self.assertFalse(store._resident_compatible())

if __name__=='__main__':unittest.main()
