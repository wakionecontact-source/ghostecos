import asyncio
from datetime import datetime
from io import BytesIO
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
from PIL import Image
import media_services_v2 as services
import media_quotas_v2 as quotas
import file_analyzer

def generate_audio(path, seconds):
    subprocess.run(
        ["ffmpeg","-hide_banner","-loglevel","error","-nostdin","-y",
         "-f","lavfi","-i","sine=frequency=650:sample_rate=16000",
         "-t",str(seconds),"-c:a","libopus","-b:a","16k",str(path)],
        check=True,timeout=45
    )
def generate_video(path, seconds):
    subprocess.run(
        ["ffmpeg","-hide_banner","-loglevel","error","-nostdin","-y",
         "-f","lavfi","-i","color=c=blue:s=128x72:r=1",
         "-t",str(seconds),"-c:v","libx264","-preset","ultrafast",
         "-pix_fmt","yuv420p",str(path)],
        check=True,timeout=45
    )

async def main():
    with tempfile.TemporaryDirectory(prefix="ghogem-v2-media-test-") as folder:
        uid=987654116
        home=Path(folder)/str(uid)
        home.mkdir()
        audio=home/"long_audio.ogg"
        generate_audio(audio,125)
        transcribed=[]
        async def fake_stt(path):
            transcribed.append(services.probe_duration(path))
            return f"Слова из фрагмента {len(transcribed)}"
        async def fake_analyze_text(*args,**kwargs):
            return "Анализ сегмента "+str(kwargs["task"])+": "+str(args[1])[:130]
        old_ask=file_analyzer._ask_text_analyzer
        file_analyzer._ask_text_analyzer=fake_analyze_text
        fake_ai=SimpleNamespace(
            USERS_DIR=folder,transcribe_audio=fake_stt,
            file_analyzer=file_analyzer,
        )
        try:
            report=await services.analyze_with_quota(
                fake_ai,uid,False,path=str(audio),filename=audio.name,
                task="Расскажи что записано",user_prompt="Проверка",
                output_format="Текст",writer_model_key="test",
            )
            assert "обрезана" in report and "65.0 с НЕ прослушаны" in report,report[:200]
            assert len(transcribed)==1 and 58<transcribed[0]<=61,transcribed
            assert quotas.usage(folder,uid,False)["audio"]["used"]==1
            again=await services.analyze_with_quota(
                fake_ai,uid,False,path=str(audio),filename=audio.name,
                task="Перепроверь",user_prompt="Проверка",output_format="Текст",
                writer_model_key="test"
            )
            assert quotas.usage(folder,uid,False)["audio"]["used"]==1
            assert "обрезана" in again
            print("PASS AUDIO FREE: 60-second truncation, explicit note, same-file quota dedupe")
            transcribed.clear()
            premium=await services.analyze_with_quota(
                fake_ai,uid,True,path=str(audio),filename=audio.name,
                task="Изучи всё",user_prompt="Проверка",output_format="Текст",
                writer_model_key="test",
            )
            assert len(transcribed)==2 and 119<transcribed[0]<=121 and 4<transcribed[1]<6,transcribed
            assert "последовательно обработаны" in premium
            print("PASS AUDIO PREMIUM: 125 seconds examined as 120+5; one file quota")
        finally:
            file_analyzer._ask_text_analyzer=old_ask
        image=home/"photo.png"
        Image.new("RGB",(100,100),"white").save(image)
        calls=[]
        async def fake_vision(*args,**kwargs):
            calls.append(args)
            return "[vision:testmodel]\nНа изображении есть текст."
        fake_ai.analyze_image=fake_vision
        fake_ai.pick_vision_model=lambda premium:"openrouter:gemma-4-31b"
        fake_ai.split_vision_result=lambda data: ("testmodel",data.split("\n",1)[1])
        basic=await services.analyze_with_quota(
            fake_ai,uid,False,path=str(image),filename=image.name,
            task="Прочитай",user_prompt="test",output_format="test",
            writer_model_key="test",analysis_mode="fast"
        )
        assert len(calls)==1 and "testmodel" in basic
        denied=await services.analyze_with_quota(
            fake_ai,uid,False,path=str(image),filename=image.name,
            task="Прочитай",user_prompt="test",output_format="test",
            writer_model_key="test",analysis_mode="reasoning"
        )
        assert "Premium" in denied and len(calls)==1
        deep=await services.analyze_with_quota(
            fake_ai,uid,True,path=str(image),filename=image.name,
            task="Прочитай",user_prompt="test",output_format="test",
            writer_model_key="test",analysis_mode="reasoning"
        )
        assert len(calls)==3 and "двумя независимыми" in deep
        print("PASS IMAGES: Free fast unlimited; Premium two-pass reasoning; Free deep denied")
        video=home/"movie.mp4"
        generate_video(video,72)
        seen=[]
        async def fake_file_analyze(**kwargs):
            seen.append(kwargs)
            return "[analyzer]\n4 кадра осмотрены"
        fake_ai.file_analyzer=SimpleNamespace(analyze_file=fake_file_analyze)
        free=await services.analyze_with_quota(
            fake_ai,uid,False,path=str(video),filename=video.name,
            task="Просмотри",user_prompt="test",output_format="test",
            writer_model_key="test",
        )
        assert "первые 20 с" in free and seen[-1]["duration_seconds"]==20
        assert quotas.usage(folder,uid,False)["video"]["used"]==1
        premium=await services.analyze_with_quota(
            fake_ai,uid,True,path=str(video),filename=video.name,
            task="Просмотри",user_prompt="test",output_format="test",
            writer_model_key="test",
        )
        assert "первые 60 с" in premium and seen[-1]["duration_seconds"]==60
        assert quotas.usage(folder,uid,False)["video"]["used"]==1
        print("PASS VIDEO: Free 20sec/Premium 60sec; no frames beyond tier cap; quota once")
        # Mock generated speech so the provider is not charged.
        fake_mp3=home/"source.mp3"
        subprocess.run(
            ["ffmpeg","-hide_banner","-loglevel","error","-nostdin","-y",
             "-f","lavfi","-i","sine=frequency=500:sample_rate=16000",
             "-t","0.8","-c:a","libmp3lame",str(fake_mp3)],check=True
        )
        async def fake_fish(text,out,**kwargs):
            Path(out).write_bytes(fake_mp3.read_bytes())
            return out
        fake_ai.fish_tts_available=lambda:True
        fake_ai.fish_tts=fake_fish
        fake_ai.get_current_chat=lambda _: "1740000000000"
        fake_ai.resolve_user_upload=lambda uid,cid,filename: str(home/filename)
        stored=await services.speech_to_media(fake_ai,uid,False,"Привет")
        assert not stored.get("error"),stored
        assert stored["area"]=="media"
        assert quotas.usage(folder,uid,False)["tts"]["used"]==1
        stored2=await services.speech_to_media(fake_ai,uid,True,"Второй тест")
        assert not stored2.get("error"),stored2
        assert quotas.usage(folder,uid,True)["tts"]["used"]==2
        print("PASS TTS: shared Free/Premium media output and hourly accounting")
asyncio.run(main())
