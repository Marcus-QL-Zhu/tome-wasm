"""Read admitted native PNGs on demand. Never extract an entire installation."""
from pathlib import Path, PurePosixPath
import hashlib
import json
import os
import threading
import zipfile

DEFAULT_INSTALL=Path(os.environ.get('TOME_NATIVE_INSTALL',r'C:\Program Files (x86)\Steam\steamapps\common\TalesMajEyal'))
ARCHIVES=('game/modules/tome-gfx.team','game/modules/tome.team','game/engines/te4-1.7.6.teae')


def asset_name(name):
    if not isinstance(name,str) or not name.startswith('data/gfx/') or not name.endswith('.png') or any(x in name for x in ('\\',':','%','\x00')):
        raise ValueError('invalid asset name')
    if any(x in ('','..','.') for x in name.split('/')): raise ValueError('invalid asset path')
    return str(PurePosixPath(name))


class AssetStore:
    def __init__(self,extracted,overlay=None,archives=()):
        self.extracted=Path(extracted).resolve();self.overlay=Path(overlay).resolve() if overlay else None
        self.files={};self.zips={};self.lock=threading.RLock();self.read_count=0;self.open_archives={};self.archive_count=0;self.missing_archives=[]
        for path in map(Path,archives):
            if not path.is_file():self.missing_archives.append(path.name);continue
            self.archive_count+=1
            with zipfile.ZipFile(path) as archive:
                for info in archive.infolist():
                    if not info.filename.startswith('data/gfx/') or not info.filename.endswith('.png'):continue
                    try:rel=asset_name(info.filename)
                    except ValueError:continue
                    if info.file_size>16*1024*1024:continue
                    if rel in self.zips:
                        previous=self.zips[rel]
                        if previous[1:3]!=(info.CRC,info.file_size):raise ValueError('ambiguous native image '+rel)
                    else:self.zips[rel]=(str(path.resolve()),info.CRC,info.file_size)
        for base in (self.extracted,self.overlay):
            if not base or not (base/'manifest.json').is_file():continue
            manifest=json.loads((base/'manifest.json').read_text(encoding='utf-8'))
            if manifest.get('version')!=1:raise ValueError('invalid asset manifest')
            for name,record in manifest['assets'].items():
                rel=asset_name(name);target=(base/rel).resolve();target.relative_to(base)
                if base==self.overlay and not rel.startswith('data/gfx/encounter/'):raise ValueError('overlay cannot replace native rules or art')
                self.files[rel]=(target,record)

    def read(self,name):
        rel=asset_name(name)
        with self.lock:
            if rel in self.files:
                path,record=self.files[rel]
                if path.stat().st_size>16*1024*1024:raise ValueError('asset too large')
                data=path.read_bytes()
                if record.get('sha256') and hashlib.sha256(data).hexdigest()!=record['sha256']:raise ValueError('asset identity mismatch')
            elif rel in self.zips:
                path,crc,size=self.zips[rel]
                if path not in self.open_archives:self.open_archives[path]=zipfile.ZipFile(path)
                archive=self.open_archives[path];info=archive.getinfo(rel)
                if (info.CRC,info.file_size)!=(crc,size):raise ValueError('archive changed')
                data=archive.read(info)
            else:raise FileNotFoundError(rel)
            if not data.startswith(b'\x89PNG\r\n\x1a\n'):raise ValueError('invalid PNG')
            self.read_count+=1
            return data,hashlib.sha256(data).hexdigest()

    def catalog(self):
        return {'format':'tome-assets-v1','images':len(set(self.files)|set(self.zips)),'loaded_images':self.read_count,'on_demand':True,'native_archives':self.archive_count,'missing_archives':self.missing_archives}

    def close(self):
        for archive in self.open_archives.values():archive.close()
        self.open_archives.clear()
