import tempfile
import unittest
from pathlib import Path
from timing import Tracker, align


class TimingTests(unittest.TestCase):
    def test_repeated_words_choose_earliest_source(self):
        pairs = align(['the', 'cache', 'the', 'cache'], [dict(word='the', start=0, end=.1), dict(word='cache', start=.1, end=.5)])
        self.assertEqual([p['index'] for p in pairs], [0, 1])

    def test_incremental_offsets_and_paragraph_reset(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'audio.pcm'
            path.write_bytes(b'\0' * 96000)
            tracker = Tracker()
            request = dict(segment='a:0', paths=[str(path)], words=[dict(text='hello', location=7, length=5)], offset=2)
            recognize = lambda pcm, offset: ({}, [dict(word='hello', start=.1, end=.5)], .01)
            self.assertEqual(tracker.update(request, recognize), [dict(location=7, length=5, start=2.1, end=2.5)])
            self.assertEqual(tracker.update(request, recognize), [])
            request['segment'] = 'b:0'
            self.assertEqual(len(tracker.update(request, recognize)), 1)

    def test_unrelated_recognition_holds_and_recovers(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'audio.pcm'
            path.write_bytes(b'\0' * 96000)
            request = dict(segment='a', paths=[str(path)], words=[dict(text='hello', location=0, length=5)], offset=0)
            tracker = Tracker()
            def recognition(word):
                return lambda pcm, offset: ({}, [dict(word=word, start=0, end=.5)], .01)
            self.assertEqual(tracker.update(request, recognition('different')), [])
            self.assertEqual(tracker.cursor, 0)
            self.assertEqual(len(tracker.update(request, recognition('hello'))), 1)
            locked = dict(tracker.locked)
            self.assertEqual(tracker.update(request, recognition('different')), [])
            self.assertEqual(tracker.cursor, 1)
            self.assertEqual(tracker.locked, locked)
            self.assertEqual(tracker.update(request, lambda pcm, offset: ({}, [], .01)), [])
            self.assertEqual(tracker.locked, locked)

    def test_recovery_can_find_position_beyond_normal_search_window(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'audio.pcm'
            path.write_bytes(b'\0' * 96000)
            reference = [dict(text=f'word{i}', location=i * 10, length=6) for i in range(120)]
            request = dict(segment='a', paths=[str(path)], words=reference, offset=0)
            tracker = Tracker()
            def recognition(indices):
                return lambda pcm, offset: ({}, [dict(word=f'word{i}', start=k * .1, end=(k+1) * .1)
                                                  for k, i in enumerate(indices)], .01)
            self.assertEqual(len(tracker.update(request, recognition([0, 1, 2]))), 3)
            self.assertEqual(tracker.update(request, recognition([90, 91, 92])), [])
            recovered = tracker.update(request, recognition([95, 96, 97]))
            self.assertEqual([word['location'] for word in recovered], [950, 960, 970])
            self.assertEqual(tracker.cursor, 98)
            request['segment'] = 'next'
            self.assertEqual(len(tracker.update(request, recognition([0, 1, 2]))), 3)
            self.assertFalse(tracker.recovering)


if __name__ == '__main__':
    unittest.main()
