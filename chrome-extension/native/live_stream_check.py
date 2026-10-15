"""Opt-in integration check: start PA3 first; no audio is played by this test."""
import base64
import json
import math
import os
from pathlib import Path
import select
import struct
import subprocess
import time
from reedah_native_host import PA3Client

class Bridge:
    def __init__(self, texts, window=2):
        self.process = subprocess.Popen([str(Path(__file__).with_name("reedah_native_host.py"))],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.send({"action":"speak", "utteranceId":"integration", "window":window,
                   "sentenceJobs":[{"index":i,"location":0,"length":len(text),"text":text} for i,text in enumerate(texts)]})
    def send(self, message):
        data=json.dumps(message).encode()
        self.process.stdin.write(struct.pack("=I",len(data))+data); self.process.stdin.flush()
    def read(self, count):
        data=b""; deadline=time.monotonic()+40
        while len(data)<count:
            left=deadline-time.monotonic()
            assert left>0 and select.select([self.process.stdout],[],[],left)[0], "Bridge timed out"
            part=os.read(self.process.stdout.fileno(),count-len(data)); assert part, "Bridge closed"
            data+=part
        return data
    def event(self):
        result=json.loads(self.read(struct.unpack("=I",self.read(4))[0]))
        assert result["event"]!="error", result
        return result
    def until(self, kind):
        pieces=[]
        while True:
            event=self.event()
            if event["event"]=="audio_chunk":
                pieces.append(event["audioBase64"])
                if event["final"]:
                    raw=base64.b64decode("".join(pieces));pieces=[]
                    assert len(raw)==event["samples"]*4
                    assert all(math.isfinite(x[0]) for x in struct.iter_unpack("<f",raw))
            if event["event"]==kind: return event
    def quiet(self):
        assert not select.select([self.process.stdout],[],[],0.3)[0], "Generation escaped its playback window"
    def close(self):
        self.process.stdin.close()
        try: self.process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.process.terminate(); self.process.wait(timeout=3)

client=PA3Client()
assert client.request("GET","/health")["active_id"] is None, "Run when PA3 narration is idle"
a=Bridge(["The first sentence is ready.", "The second sentence waits for its turn.", "The third sentence follows playback."],1)
try:
    assert a.until("audio_end")["index"]==0; a.quiet()
    a.send({"action":"window","window":2})
    assert a.until("audio_end")["index"]==1; a.quiet()
    a.send({"action":"consumed","index":0})
    assert a.until("audio_end")["index"]==2; a.until("finished")
    print("PASS live prefetch promotion and playback backpressure",flush=True)
finally: a.close()

# Browser/unit tests assert exact formula speech and source offsets. Here check
# that representative prepared speech also survives the real bridge and Qwen
# streaming path. This validates audio transport, not acoustic pronunciation.
a=Bridge([
    "The value of x squared plus y squared equals z squared.",
    "Read fraction alpha plus 1 over square root of beta end root end fraction."
])
try:
    for index in range(2):
        event=a.until("audio_end")
        assert event["index"]==index and event["chunks"]>0, event
    a.until("finished")
    print("PASS live mathematical speech: powers, Greek letters, nested fraction and root",flush=True)
finally: a.close()

long_text="The audio begins while the speech model continues generating the rest of this sentence, and cancelling this request should clean up its temporary audio without cancelling a separate request from another browser tab."
a=Bridge([long_text]); b=None
try:
    a.until("audio_chunk")
    own=client.request("GET","/health")["active_id"]; assert own
    b=Bridge(["The second browser tab continues normally."])
    a.send({"action":"stop"}); a.until("cancelled")
    assert client.request("GET","/v1/narrations/"+own)["state"]=="cancelled"
    try:
        client.request("GET","/v1/narrations/"+own+"/chunks/0",audio=True)
        raise AssertionError("Cancelled audio remained readable")
    except RuntimeError as error: assert "404" in str(error)
    b.until("finished")
    print("PASS concurrent bridges: cancellation cleans up only its own job",flush=True)
finally:
    a.close()
    if b: b.close()
