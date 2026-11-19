from pathlib import Path
import tempfile
import unittest
import zipfile
from tome_mvp.wasm.asset_store import AssetStore

class AssetStoreTests(unittest.TestCase):
 def test_lazy_archive_read_and_traversal_rejection(self):
  with tempfile.TemporaryDirectory() as temp:
   root=Path(temp);path=root/'art.team';png=b'\x89PNG\r\n\x1a\nfixture'
   with zipfile.ZipFile(path,'w') as archive:
    archive.writestr('data/gfx/effects/confused.png',png);archive.writestr('not-an-image.lua','private')
   store=AssetStore(root/'empty',archives=[path]);self.assertEqual(store.catalog()['images'],1);self.assertEqual(store.read_count,0)
   self.assertEqual(store.read('data/gfx/effects/confused.png')[0],png);self.assertEqual(store.read_count,1)
   for p in ('data/gfx/../secret.png','data/gfx/a\\b.png','data/gfx/x.lua'):
    with self.assertRaises(ValueError):store.read(p)
   with self.assertRaises(FileNotFoundError):store.read('data/gfx/missing.png')
   store.close()

if __name__=='__main__':unittest.main()
