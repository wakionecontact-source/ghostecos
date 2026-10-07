import asyncio
from pathlib import Path
import tempfile
import subprocess
import ai
import media_quotas_v2 as q
import media_services_v2 as sv
import file_analyzer

async def main():
    oldroot = ai.USERS_DIR
    oldtts = ai.fish_tts
    oldavailable = ai.fish_tts_available
    oldstt = ai.transcribe_audio
    oldanalysis = file_analyzer.analyze_file
    oldtextanalysis=file_analyzer._ask_text_analyzer
    try:
        with tempfile.TemporaryDirectory(prefix="ghogem-q-tests-") as root:
            ai.USERS_DIR=root
            uid=12345
            folder=Path(root)/str(uid)/"media"
            folder.mkdir(parents=True)
            source=folder/"example.mp3"
            subprocess.run(["ffmpeg","-nostdin","-loglevel","error","-y",
                "-f","lavfi","-i","sine=frequency=700:sample_rate=16000",
                "-t","122","-c:a","libmp3lame","-b:a","24k",str(source)],
                check=True,timeout=20)
            assert 121<sv.probe_duration(str(source))<123
            observed=[]
            async def fake_stt(path):
                observed.append(sv.probe_duration(path))
                return "Пример распознанной речи"
            ai.transcribe_audio=fake_stt
            first=await sv.transcribe_with_quota(ai,uid,False,str(source))
            assert "обрезана" in first and len(observed)==1
            assert 59<=observed[0]<=61
            second=await sv.transcribe_with_quota(ai,uid,True,str(source))
            assert "2 части" in second and len(observed)==3, (second, observed)
            assert max(observed)<=120.2
            assert q.usage(root,uid,False)["audio"]["used"]==1
            print("PASS: Free cuts 60s, Premium processes all 122s in 120s chunks, one file one slot")
            clip=folder/"clip.mp4"
            subprocess.run(["ffmpeg","-nostdin","-loglevel","error","-y",
                "-f","lavfi","-i","color=c=blue:s=160x90:r=2",
                "-t","25","-c:v","libx264","-preset","ultrafast",str(clip)],
                check=True,timeout=20)
            captured=[]
            async def fake_file_analyzer(**args):
                captured.append((args["duration_seconds"],args["start_second"]))
                return "Кадры проанализированы"
            file_analyzer.analyze_file=fake_file_analyzer
            out=await sv.analyze_with_quota(ai,uid,False,path=str(clip),
                    filename=clip.name,task="изучи",user_prompt="видео",
                    output_format="",writer_model_key=ai.DEFAULT_MODEL_KEY)
            assert "первые 20" in out and captured[-1][0]<=20.001
            out2=await sv.analyze_with_quota(ai,uid,True,path=str(clip),
                    filename=clip.name,task="изучи",user_prompt="видео",
                    output_format="",writer_model_key=ai.DEFAULT_MODEL_KEY)
            assert captured[-1][0]==60
            assert q.usage(root,uid,False)["video"]["used"]==1
            print("PASS: video duration limited to 20s/60s, shared quota across repeat analysis")
            fake_mp3 = (folder/"output.mp3")
            subprocess.run(["ffmpeg","-nostdin","-loglevel","error","-y",
                "-f","lavfi","-i","sine=frequency=600:sample_rate=16000",
                "-t","0.8","-c:a","libmp3lame","-b:a","24k",str(fake_mp3)],
                check=True,timeout=20)
            binary=fake_mp3.read_bytes()
            async def fake_tts(text,out_path,**kwargs):
                Path(out_path).write_bytes(binary)
                return out_path
            ai.fish_tts=fake_tts
            ai.fish_tts_available=lambda:True
            for i in range(5):
                result=await sv.speech_to_media(ai,uid,False,f"Тест {i}")
                assert not result.get("error"),result
            denied=await sv.speech_to_media(ai,uid,False,"Шестой")
            assert denied.get("error") and "Лимит" in denied["error"],denied
            premium=await sv.speech_to_media(ai,uid,True,"Премиум")
            assert not premium.get("error"),premium
            assert q.usage(root,uid,False)["tts"]["used"]==6
            print("PASS: 5 Free TTS / hour, 30 Premium / hour, generated media saved")
            txt=folder/"picture.png"
            txt.write_bytes(b"x")
            result=await sv.analyze_with_quota(ai,uid,False,path=str(txt),
                filename="picture.png",task="inspect",user_prompt="q",
                output_format="",writer_model_key=ai.DEFAULT_MODEL_KEY,
                analysis_mode="reasoning")
            assert result.startswith("🔒"),result
            print("PASS: Free deep photo analysis denied")
    finally:
        ai.USERS_DIR=oldroot
        ai.fish_tts=oldtts
        ai.fish_tts_available=oldavailable
        ai.transcribe_audio=oldstt
        file_analyzer.analyze_file=oldanalysis
        file_analyzer._ask_text_analyzer=oldtextanalysis

asyncio.run(main())
