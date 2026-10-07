"""Stub remote model providers; exercise actual limits/transcoding/storage."""
import asyncio
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from PIL import Image
import ai
import media_services_v2 as services
import media_quotas_v2 as quotas

async def main():
    root_old=ai.USERS_DIR
    transcribe_old=ai.transcribe_audio
    speech_old=ai.fish_tts
    available_old=ai.fish_tts_available
    vision_old=ai.analyze_image
    vision_pick_old=ai.pick_vision_model
    analyzer_old=ai.file_analyzer.analyze_file
    with tempfile.TemporaryDirectory(prefix="ghogem-media-test-") as root:
        ai.USERS_DIR=root
        aroot=Path(root)/"991"; aroot.mkdir()
        bpath=Path(root)/"992"; bpath.mkdir()
        sample=Path(root)/"sample.mp3"
        afile=aroot/"long.ogg"
        vfile=aroot/"video.mp4"
        print("Generating test media locally")
        for args in (
            ["ffmpeg","-hide_banner","-loglevel","error","-y","-f","lavfi",
             "-i","sine=frequency=600:sample_rate=16000","-t","1",
             "-c:a","libmp3lame",str(sample)],
            ["ffmpeg","-hide_banner","-loglevel","error","-y","-f","lavfi",
             "-i","sine=frequency=440:sample_rate=16000","-t","150",
             "-c:a","libopus","-b:a","20k",str(afile)],
            ["ffmpeg","-hide_banner","-loglevel","error","-y","-f","lavfi",
             "-i","color=c=blue:size=64x64:rate=1","-t","30",
             "-c:v","mpeg4",str(vfile)],
        ):
            subprocess.run(args,check=True,timeout=45)
        calls=[]
        async def speech(text,out,**kwargs):
            calls.append(("tts",text))
            shutil.copy(sample,out)
            return out
        async def transcribe(path):
            calls.append(("stt",Path(path).name))
            return "распознанные слова"
        async def analyzer(**kwargs):
            calls.append(("file_analyzer",kwargs["duration_seconds"] if "duration_seconds" in kwargs else None))
            return "Наблюдения анализатора"
        async def vision(path,task,model,**kwargs):
            calls.append(("vision",task[:24]))
            return "[vision:dummy]\nВижу тестовую картинку."
        ai.fish_tts=speech
        ai.fish_tts_available=lambda:True
        ai.transcribe_audio=transcribe
        ai.analyze_image=vision
        ai.pick_vision_model=lambda premium:"dummy-premium"
        try:
            for index in range(5):
                result=await services.speech_to_media(ai,991,False,f"Speech {index}",chat_id="1740000000000")
                assert "name" in result, result
            sixth=await services.speech_to_media(ai,991,False,"Sixth",chat_id="1740000000000")
            assert sixth.get("error","").startswith("⛔"),sixth
            assert len([x for x in calls if x[0]=="tts"])==5
            assert quotas.usage(root,991,False)["tts"]=={"used":5,"limit":5,"remaining":0}
            print("PASS: Free TTS five per hour, sixth rejected before external provider call")
            calls.clear()
            for index in range(30):
                result=await services.speech_to_media(ai,992,True,"Speech",chat_id="1740000000000")
                assert "name" in result,result
            blocked=await services.speech_to_media(ai,992,True,"31st",chat_id="1740000000000")
            assert blocked.get("error","").startswith("⛔")
            assert len(calls)==30
            print("PASS: Premium TTS thirty per hour, same shared quota in SQLite")
            calls.clear()
            free=await services.transcribe_with_quota(ai,991,False,str(afile))
            assert "150.0" in free and "60" in free and "НЕ прослушаны" in free,free
            assert len([x for x in calls if x[0]=="stt"])==1
            assert quotas.usage(root,991,False)["audio"]["used"]==1
            print("PASS: Free audio only first 60s, cutoff disclosed, counts one upload")
            calls.clear()
            premium_audio=bpath/"long.ogg";shutil.copy(afile,premium_audio)
            premium=await services.transcribe_with_quota(ai,992,True,str(premium_audio))
            assert "последовательно обработаны все 2 части" in premium,premium
            assert len([x for x in calls if x[0]=="stt"])==2
            assert quotas.usage(root,992,True)["audio"]["used"]==1
            print("PASS: Premium 150s audio split 120+30, counted one slot")
            calls.clear()
            ai.file_analyzer.analyze_file=analyzer
            video=await services.analyze_with_quota(
                ai,991,False,path=str(vfile),filename="video.mp4",task="Check",
                user_prompt="Summarize",output_format="",writer_model_key="dummy")
            assert "первые 20" in video,video
            assert calls[0][1]==20,calls
            before=quotas.usage(root,991,False)["video"]["used"]
            again=await services.analyze_with_quota(
                ai,991,False,path=str(vfile),filename="video.mp4",task="Other task",
                user_prompt="Summarize",output_format="",writer_model_key="dummy")
            assert again and quotas.usage(root,991,False)["video"]["used"]==before
            print("PASS: video limited to 20 seconds Free and repeat call doesn't charge another slot")
            ai.file_analyzer.analyze_file=analyzer_old
            photo=aroot/"photo.png";Image.new("RGB",(64,64),"white").save(photo)
            denied=await services.analyze_with_quota(
                ai,991,False,path=str(photo),filename="photo.png",task="Inspect",
                user_prompt="Inspect",output_format="",writer_model_key="dummy",
                analysis_mode="reasoning")
            assert denied.startswith("🔒")
            calls.clear()
            detailed=await services.analyze_with_quota(
                ai,991,True,path=str(photo),filename="photo.png",task="Inspect",
                user_prompt="Inspect",output_format="",writer_model_key="dummy",
                analysis_mode="reasoning")
            assert "двумя независимыми проходами" in detailed,detailed
            assert len([x for x in calls if x[0]=="vision"])==2
            print("PASS: Free reasoning denied, Premium image analysis performs two independent checks")
        finally:
            ai.USERS_DIR=root_old
            ai.transcribe_audio=transcribe_old
            ai.fish_tts=speech_old
            ai.fish_tts_available=available_old
            ai.analyze_image=vision_old
            ai.pick_vision_model=vision_pick_old
            ai.file_analyzer.analyze_file=analyzer_old

asyncio.run(main())
