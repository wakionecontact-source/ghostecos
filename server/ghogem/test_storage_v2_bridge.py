import asyncio
from io import BytesIO
import json
import os
from pathlib import Path
import tempfile
from PIL import Image
from starlette.datastructures import UploadFile
import ai
import bot
import storage_v2
import web_api

async def test():
    old_base=ai.USERS_DIR
    with tempfile.TemporaryDirectory(prefix='ghogem-v2-bridge-') as tmp:
        ai.USERS_DIR=tmp
        uid=998877665544
        ai.user_current_chat[uid]='1234567890000'
        (Path(tmp)/str(uid)/'chats'/'1234567890000'/'files').mkdir(parents=True)
        pic=BytesIO()
        Image.new('RGBA',(300,250),(120,60,200,170)).save(pic,'PNG')
        rgba=pic.getvalue()
        image=ai.save_user_upload(uid,'1234567890000','sample.png',rgba)
        assert image['area']=='media' and Path(image['path']).is_file()
        assert not list((Path(tmp)/str(uid)/'chats'/'1234567890000'/'files').glob('*.png'))
        assert ai.resolve_user_upload(uid,'1234567890000',image['name'])==image['path']
        record=storage_v2.list_temporary(tmp,uid,area='media',premium=False)
        assert record['limit']==25*storage_v2.MIB and record['files']
        print('PASS: media->user shared, compression, quotas and resolver')
        text=ai.save_user_upload(uid,'1234567890000','notes.txt',b'test notes')
        assert text['area']=='main' and Path(text['path']).read_text()=='test notes'
        emerg=ai.save_user_upload(uid,'1234567890000','urgent.txt',b'today exam',
                                  target='buffer',urgent=True)
        assert emerg['area']=='buffer'
        assert Path(emerg['path']).read_text()=='today exam'
        assert not any(e['original_name']=='notes.txt' for e in record['files'])
        try:ai.save_user_upload(uid,'1234567890000','wrong.txt',b'x',target='media')
        except storage_v2.StorageError:pass
        else:raise AssertionError('text in media')
        try:ai.save_user_upload(uid,'1234567890000','clip.mp4',b'not-video')
        except storage_v2.StorageError:pass
        else:raise AssertionError('fake video accepted')
        try:ai.resolve_user_upload(uid+1,'1234567890000',image['name'])
        except Exception:pass
        print('PASS: documents->main, urgent buffer, media type isolation')
        uid2=uid+1
        ai.user_current_chat[uid2]='1234567890000'
        (Path(tmp)/str(uid2)/'chats'/'1234567890000'/'files').mkdir(parents=True)
        assert ai.resolve_user_upload(uid2,'1234567890000',image['name']) != image['path']
        assert not Path(ai.resolve_user_upload(uid2,'1234567890000',image['name'])).exists()
        print('PASS: cross-owner filesystem separation')
        ident=web_api.Ident(uid=uid,kind='tg')
        response=await web_api.files_upload(
            file=UploadFile(file=BytesIO(rgba),filename='web-photo.png'),
            ident=ident,
        )
        assert response['area']=='media'
        listed=web_api.files(ident=ident)
        assert any(row.get('area')=='media' and row['name']==response['name'] for row in listed['files'])
        assert len(web_api.files_raw(name=response['name'],ident=ident).body)>0
        buffered=await web_api.files_upload(
            file=UploadFile(file=BytesIO(b'next exam'),filename='web-urgent.txt'),
            storage_area='buffer',ident=ident,
        )
        assert buffered['area']=='buffer'
        assert any(row['name']==buffered['name'] for row in web_api.buffer_files(ident=ident)['files'])
        print('PASS: web upload/media listing, authenticated file retrieval, urgent buffer')
        bot.buffer_upload_mode.add(uid)
        try:
            newpath,note=await bot._save_bytes_to_chat(uid,'question.png',rgba)
            assert '/buffer/' in newpath and 'Аварийный буфер' in note,note
        finally:
            bot.buffer_upload_mode.discard(uid)
        normalpath,note=await bot._save_bytes_to_chat(uid,'picture.png',rgba)
        assert '/media/' in normalpath and 'Общее медиа' in note
        print('PASS: Telegram uploader selects buffer/media by request')
        raw_index=Path(tmp)/str(uid)/'temporary_storage_v2.json'
        data=json.loads(raw_index.read_text())
        data['media'][image['name']]['expires_at']=1
        data['media'][image['name']]['lease_until']=0
        raw_index.write_text(json.dumps(data))
        removed=storage_v2.cleanup_expired(tmp,uid)
        assert removed['media']==1
        assert not Path(image['path']).exists()
        assert Path(emerg['path']).exists()
        print('PASS: expired entries deleted without touching other user files')
    ai.USERS_DIR=old_base

asyncio.run(test())
