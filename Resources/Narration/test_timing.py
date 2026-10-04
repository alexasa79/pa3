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

    def test_unrelated_recognition_stops(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'audio.pcm'
            path.write_bytes(b'\0' * 96000)
            request = dict(segment='a', paths=[str(path)], words=[dict(text='hello', location=0, length=5)], offset=0)
            with self.assertRaisesRegex(RuntimeError, 'could not align'):
                Tracker().update(request, lambda pcm, offset: ({}, [dict(word='different', start=0, end=.5)], .01))


if __name__ == '__main__':
    unittest.main()
