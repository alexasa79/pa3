import base64
import io
import json
import struct
import threading
import unittest
from native.reedah_native_host import NativeMessenger, SentenceWindow, narrate, validate_jobs


class Messenger:
    def __init__(self): self.events = []
    def send(self, event): self.events.append(event)


class Client:
    def __init__(self, state="completed", audio=b"\0" * 600000):
        self.calls = []
        self.state = state
        self.audio = audio
    def request(self, method, path, payload=None, audio=False):
        self.calls.append((method, path, payload))
        if method == "DELETE": return {}
        if audio: return self.audio
        return {"id": "abc-123", "state": self.state, "error": "fixture failure", "audio_chunks": [{"samples": len(self.audio) // 4, "sample_rate": 24000}]}


class HostTests(unittest.TestCase):
    def message(self):
        return {"utteranceId": "test", "sentenceJobs": [{"index": 2, "location": 12, "length": 8, "text": "P A three"}]}

    def test_audio_is_chunked_and_job_released(self):
        client, messenger = Client(), Messenger()
        narrate(self.message(), messenger, threading.Event(), lambda: client)
        self.assertEqual(client.calls[0][2], {"text": "P A three", "output": "stream"})
        chunks = [e for e in messenger.events if e["event"] == "audio_chunk"]
        self.assertGreater(len(chunks), 1)
        self.assertEqual(base64.b64decode("".join(c["audioBase64"] for c in chunks)), client.audio)
        self.assertTrue(chunks[-1]["final"])
        for i, chunk in enumerate(chunks):
            self.assertEqual(chunk["part"], i)
            self.assertEqual((chunk["index"], chunk["location"], chunk["length"]), (2, 12, 8))
            self.assertLess(len(json.dumps(chunk)), 1024 * 1024)
        self.assertIn(("DELETE", "/v1/narrations/abc-123", None), client.calls)
        self.assertEqual(messenger.events[-1]["event"], "finished")

    def test_sends_each_sentence_before_requesting_the_next(self):
        messenger = Messenger()
        class SequentialClient(Client):
            def request(inner, method, path, payload=None, audio=False):
                if method == "POST" and any(call[0] == "POST" for call in inner.calls):
                    self.assertEqual(messenger.events[-1]["event"], "audio_end")
                    self.assertEqual(messenger.events[-1]["index"], 2)
                return super().request(method, path, payload, audio)
        message = self.message()
        message["sentenceJobs"].append({"index": 3, "location": 21, "length": 7, "text": "Next up"})
        client = SequentialClient(audio=b"RIFFtest")
        narrate(message, messenger, threading.Event(), lambda: client)
        self.assertEqual([call[2]["text"] for call in client.calls if call[0] == "POST"], ["P A three", "Next up"])
        self.assertEqual([event["index"] for event in messenger.events if event["event"] == "audio_chunk"], [2, 3])
        self.assertEqual(messenger.events[-1]["event"], "finished")

    def test_first_piece_is_delivered_before_sentence_finishes(self):
        messenger = Messenger()
        class ProgressiveClient(Client):
            def request(inner, method, path, payload=None, audio=False):
                result = super().request(method, path, payload, audio)
                if audio or method == "DELETE": return result
                if method == "POST":
                    return {"id": "abc-123", "state": "generating", "audio_chunks": [{"samples":2, "sample_rate":24000}]}
                self.assertEqual(messenger.events[-1]["event"], "audio_chunk")
                self.assertEqual(messenger.events[-1]["pieceIndex"], 0)
                return {"id": "abc-123", "state": "completed", "audio_chunks": [{"samples":2, "sample_rate":24000}, {"samples":2, "sample_rate":24000}]}
        client = ProgressiveClient(audio=b"RIFFtest")
        narrate(self.message(), messenger, threading.Event(), lambda: client)
        chunks = [e for e in messenger.events if e["event"] == "audio_chunk"]
        self.assertEqual([e["pieceIndex"] for e in chunks], [0, 1])
        self.assertEqual([e["samples"] for e in chunks], [2, 2])
        self.assertTrue(all(e["stream"] for e in chunks))
        self.assertEqual(messenger.events[-2]["event"], "audio_end")
        self.assertEqual(messenger.events[-1]["event"], "finished")

    def test_failure_stops_and_cancels_only_own_job(self):
        client, messenger = Client(state="failed"), Messenger()
        narrate(self.message(), messenger, threading.Event(), lambda: client)
        self.assertEqual(messenger.events[-1]["event"], "error")
        self.assertEqual(client.calls[-1][:2], ("DELETE", "/v1/narrations/abc-123"))
        self.assertFalse(any(e["event"] == "audio_chunk" for e in messenger.events))

    def test_cancel_during_submit_cleans_up_late_accepted_job(self):
        cancelled = threading.Event()
        class CancellingClient(Client):
            def request(self, method, path, payload=None, audio=False):
                result = super().request(method, path, payload, audio)
                if method == "POST": cancelled.set()
                return result
        client, messenger = CancellingClient(state="generating"), Messenger()
        narrate(self.message(), messenger, cancelled, lambda: client)
        self.assertEqual(client.calls[-1][:2], ("DELETE", "/v1/narrations/abc-123"))
        self.assertFalse(any(e["event"] == "audio_chunk" for e in messenger.events))

    def test_rejects_pcm_size_mismatch_and_cleans_up(self):
        class TruncatedClient(Client):
            def request(inner, method, path, payload=None, audio=False):
                result = super().request(method, path, payload, audio)
                return result[:-4] if audio else result
        client, messenger = TruncatedClient(), Messenger()
        narrate(self.message(), messenger, threading.Event(), lambda: client)
        self.assertEqual(messenger.events[-1]["event"], "error")
        self.assertEqual(client.calls[-1][0], "DELETE")
        self.assertFalse(any(e["event"] == "audio_chunk" for e in messenger.events))

    def test_no_request_when_already_cancelled(self):
        cancelled = threading.Event(); cancelled.set()
        client = Client()
        narrate(self.message(), Messenger(), cancelled, lambda: client)
        self.assertEqual(client.calls, [])

    def test_native_framing_roundtrip_unicode(self):
        buffer = io.BytesIO()
        NativeMessenger(stdout=buffer).send({"text": "Привет 🌍"})
        buffer.seek(0)
        self.assertEqual(NativeMessenger(stdin=buffer).read_message(), {"text": "Привет 🌍"})

    def test_framing_rejects_truncated_and_oversized_input(self):
        for raw in [b"\x01", struct.pack("=I", 600000), struct.pack("=I", 3) + b"{}"]:
            with self.assertRaises(ValueError): NativeMessenger(stdin=io.BytesIO(raw)).read_message()

    def test_invalid_sentence_jobs(self):
        for value in [[], None, [{"text": "hello", "index": True, "location": 0, "length": 5}]]:
            with self.assertRaises(ValueError): validate_jobs(value)


class FlowTests(unittest.TestCase):
    def test_generation_waits_for_playback_and_stop_interrupts_wait(self):
        flow = SentenceWindow(1)
        cancel, acquired = threading.Event(), threading.Event()
        self.assertTrue(flow.acquire(0, cancel))
        worker = threading.Thread(target=lambda: (flow.acquire(1, cancel), acquired.set()))
        worker.start()
        self.assertFalse(acquired.wait(0.1))
        flow.consumed(0)
        self.assertTrue(acquired.wait(1)); worker.join()
        acquired.clear()
        worker = threading.Thread(target=lambda: (flow.acquire(2, cancel), acquired.set()))
        worker.start(); self.assertFalse(acquired.wait(0.1)); cancel.set()
        self.assertTrue(acquired.wait(1)); worker.join()
        self.assertEqual(flow.pending, {1})

    def test_prefetch_can_promote_to_two_slots_and_rejects_duplicate_ack(self):
        flow = SentenceWindow(1); cancel = threading.Event()
        flow.acquire(0, cancel); flow.set_limit(2); flow.acquire(1, cancel)
        flow.consumed(0)
        with self.assertRaises(ValueError): flow.consumed(0)
        with self.assertRaises(ValueError): flow.set_limit(100)

    def test_long_paragraph_has_at_most_two_unconsumed_sentences(self):
        flow = SentenceWindow(2); cancel = threading.Event()
        produced, received = [], threading.Condition()
        def generate():
            for i in range(1000):
                if not flow.acquire(i, cancel): return
                with received: produced.append(i); received.notify_all()
        worker = threading.Thread(target=generate); worker.start()
        for i in range(1000):
            with received:
                self.assertTrue(received.wait_for(lambda: len(produced)>i, timeout=2))
            self.assertLessEqual(len(produced)-i,2)
            flow.consumed(i)
        worker.join(timeout=2); self.assertFalse(worker.is_alive())


if __name__ == "__main__": unittest.main()
