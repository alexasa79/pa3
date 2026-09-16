#!/usr/bin/env python3
"""Chrome native messaging bridge to PA3. No model runtime or text processing."""
import base64
import http.client
import json
import os
from pathlib import Path
import struct
import sys
import threading
import time

MAX_MESSAGE = 512_000
MAX_AUDIO = 32 * 1024 * 1024
TOKEN_FILE = Path.home() / "Library/Application Support/PA3/narration-token"


class NativeMessenger:
    def __init__(self, stdin=None, stdout=None):
        self.stdin = stdin if stdin is not None else sys.stdin.buffer
        self.stdout = stdout if stdout is not None else sys.stdout.buffer
        self.lock = threading.Lock()

    def read_exact(self, size):
        result = bytearray()
        while len(result) < size:
            chunk = self.stdin.read(size - len(result))
            if not chunk:
                if result:
                    raise ValueError("Truncated native message")
                return None
            result.extend(chunk)
        return bytes(result)

    def read_message(self):
        header = self.read_exact(4)
        if header is None:
            return None
        size = struct.unpack("=I", header)[0]
        if not 0 < size <= MAX_MESSAGE:
            raise ValueError("Native message exceeds 512 KB")
        body = self.read_exact(size)
        if body is None:
            raise ValueError("Missing native message body")
        message = json.loads(body)
        if not isinstance(message, dict):
            raise ValueError("Native message must be an object")
        return message

    def send(self, payload):
        data = json.dumps(payload, separators=(",", ":")).encode()
        if len(data) >= 1024 * 1024:
            raise ValueError("Native response exceeds Chrome's message limit")
        with self.lock:
            self.stdout.write(struct.pack("=I", len(data)) + data)
            self.stdout.flush()


def log(message):
    print("Reedah: " + str(message), file=sys.stderr, flush=True)


class PA3Client:
    def __init__(self):
        self.port = int(os.environ.get("PA3_NARRATION_PORT", "65462"))
        self.token = TOKEN_FILE.read_text().strip()
        if not self.token:
            raise ValueError("Start PA3 to create its narration token")

    def request(self, method, path, payload=None, audio=False):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            headers = {"Authorization": "Bearer " + self.token}
            body = None
            if payload is not None:
                body = json.dumps(payload).encode()
                headers["Content-Type"] = "application/json"
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            limit = MAX_AUDIO if audio else MAX_MESSAGE
            data = response.read(limit + 1)
            if len(data) > limit:
                raise ValueError("PA3 response exceeds size limit")
            if response.status >= 400:
                detail = json.loads(data).get("error", "Request failed")
                raise RuntimeError(f"PA3 HTTP {response.status}: {detail}")
            if audio:
                if response.getheader("Content-Type") != "application/octet-stream" or not data or len(data) % 4:
                    raise ValueError("PA3 did not return float32 PCM audio")
                return data
            return json.loads(data)
        finally:
            connection.close()


def validate_jobs(value):
    if not isinstance(value, list) or not value or len(value) > 1000:
        raise ValueError("Expected 1–1000 sentence jobs")
    indices = set()
    for job in value:
        if not isinstance(job, dict) or not isinstance(job.get("text"), str) or not job["text"].strip():
            raise ValueError("Each sentence needs text")
        if len(job["text"]) > 4000:
            raise ValueError("Each sentence is limited to 4,000 characters")
        for key in ("index", "location", "length"):
            if type(job.get(key)) is not int or job[key] < 0:
                raise ValueError("Invalid sentence position")
        if job["index"] in indices: raise ValueError("Duplicate sentence index")
        indices.add(job["index"])
    return value


class SentenceWindow:
    """Bound unconsumed sentences; the browser returns a slot after play/skip."""
    def __init__(self, limit=2):
        self.condition = threading.Condition()
        self.pending = set()
        self.set_limit(limit)

    def set_limit(self, limit):
        if type(limit) is not int or not 1 <= limit <= 2:
            raise ValueError("Sentence window must be 1 or 2")
        with self.condition:
            self.limit = limit
            self.condition.notify_all()

    def acquire(self, index, cancelled):
        with self.condition:
            while len(self.pending) >= self.limit:
                if cancelled.is_set(): return False
                self.condition.wait(0.05)
            if cancelled.is_set(): return False
            self.pending.add(index)
            return True

    def consumed(self, index):
        with self.condition:
            if type(index) is not int or index not in self.pending:
                raise ValueError("Unexpected consumed sentence")
            self.pending.remove(index)
            self.condition.notify_all()


def narrate(message, messenger, cancelled, client_factory=PA3Client, flow=None):
    utterance = message.get("utteranceId")
    client = None
    path = None
    failure = None
    try:
        if not isinstance(utterance, str) or not utterance:
            raise ValueError("Missing utterance ID")
        jobs = validate_jobs(message.get("sentenceJobs"))
        flow = flow or SentenceWindow(message.get("window", 2))
        client = client_factory()
        messenger.send({"event": "started", "utteranceId": utterance,
                        "voiceName": "PA3 · American senior engineer", "voiceIdentifier": "senior-engineer-american"})
        for sentence in jobs:
            if not flow.acquire(sentence["index"], cancelled):
                return
            result = client.request("POST", "/v1/narrations", {"text": sentence["text"], "output": "stream"})
            job_id = result.get("id")
            if not isinstance(job_id, str) or not job_id or any(c not in "0123456789abcdef-" for c in job_id):
                raise ValueError("PA3 returned an invalid job ID")
            path = "/v1/narrations/" + job_id
            deadline = time.monotonic() + 600
            sent = 0
            while True:
                if cancelled.is_set():
                    return
                if result["state"] in ("failed", "cancelled"):
                    raise RuntimeError(result.get("error", "PA3 narration " + result["state"]))
                pieces = result.get("audio_chunks")
                if not isinstance(pieces, list) or len(pieces) < sent:
                    raise ValueError("PA3 returned invalid audio piece metadata")
                while sent < len(pieces):
                    if cancelled.is_set():
                        return
                    bounds = pieces[sent]
                    samples, rate = bounds.get("samples"), bounds.get("sample_rate")
                    if type(samples) is not int or not 0 < samples <= 192000 or rate != 24000:
                        raise ValueError("PA3 returned invalid PCM metadata")
                    audio = client.request("GET", path + "/chunks/" + str(sent), audio=True)
                    if len(audio) != samples * 4:
                        raise ValueError("PA3 returned truncated PCM audio")
                    encoded = base64.b64encode(audio).decode("ascii")
                    chunk_size = 256 * 1024
                    for part, offset in enumerate(range(0, len(encoded), chunk_size)):
                        if cancelled.is_set():
                            return
                        messenger.send({"event": "audio_chunk", "utteranceId": utterance,
                                        "index": sentence["index"], "location": sentence["location"], "length": sentence["length"],
                                        "pieceIndex": sent, "stream": True, "samples": samples, "sampleRate": rate,
                                        "part": part, "final": offset + chunk_size >= len(encoded),
                                        "audioBase64": encoded[offset:offset + chunk_size]})
                    sent += 1
                if result["state"] == "completed":
                    if not sent:
                        raise ValueError("PA3 completed without audio")
                    messenger.send({"event": "audio_end", "utteranceId": utterance,
                                    "index": sentence["index"], "chunks": sent})
                    break
                if cancelled.wait(0.05):
                    return
                if time.monotonic() > deadline:
                    raise TimeoutError("PA3 narration timed out")
                result = client.request("GET", path)
            client.request("DELETE", path)
            path = None
        messenger.send({"event": "finished", "utteranceId": utterance})
    except Exception as error:
        log(error)
        if not cancelled.is_set():
            failure = {"event": "error", "utteranceId": utterance,
                       "message": "pa3_error", "details": str(error) + ". Ensure PA3 is running and its models are ready."}
    finally:
        if client is not None and path is not None:
            try:
                client.request("DELETE", path)
            except Exception as error:
                log("Could not cancel PA3 job: " + str(error))
        if cancelled.is_set():
            messenger.send({"event": "cancelled", "utteranceId": utterance})
        elif failure is not None:
            messenger.send(failure)


def main():
    messenger = NativeMessenger()
    cancelled = threading.Event()
    worker = None
    flow = None
    try:
        while (message := messenger.read_message()) is not None:
            if message.get("action") == "stop":
                cancelled.set()
            elif message.get("action") == "consumed" and flow is not None:
                flow.consumed(message.get("index"))
            elif message.get("action") == "window" and flow is not None:
                flow.set_limit(message.get("window"))
            elif message.get("action") == "speak":
                if worker is not None:
                    raise ValueError("Use a new connection for each narration")
                flow = SentenceWindow(message.get("window", 2))
                worker = threading.Thread(target=narrate, args=(message, messenger, cancelled), kwargs={"flow": flow})
                worker.start()
            else:
                raise ValueError("Unknown native action")
    except Exception as error:
        log(error)
    finally:
        cancelled.set()
        if worker is not None:
            worker.join(timeout=25)


if __name__ == "__main__":
    main()
