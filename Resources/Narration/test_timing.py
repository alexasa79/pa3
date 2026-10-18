import tempfile
import unittest
from pathlib import Path
from timing import Tracker, align, join_cost


class TimingTests(unittest.TestCase):
    def test_formula_letter_names_match_recognized_letters(self):
        observed = [dict(word=word.lower(), start=i*.2, end=(i+1)*.2)
                    for i, word in enumerate(['log', 'base', 'B', 'of', 'N'])]
        pairs = align(['log', 'base', 'bee', 'of', 'en'], observed)
        self.assertEqual([pair['index'] for pair in pairs], list(range(5)))

    def test_repeated_words_choose_earliest_source(self):
        pairs = align(['the', 'cache', 'the', 'cache'], [dict(word='the', start=0, end=.1), dict(word='cache', start=.1, end=.5)])
        self.assertEqual([p['index'] for p in pairs], [0, 1])

    def test_merged_recognition_keeps_sentence_prefix(self):
        reference = ['parameter', 'a', 'ranges', 'between', '0', 'and', '1']
        observed = [dict(word=word, start=start, end=end) for word, start, end in [
            ('parameter', 0, .92), ('arranges', .92, 1.74), ('between', 1.74, 2.46),
            ('0', 2.46, 2.77), ('and', 2.77, 3.07), ('1', 3.07, 3.44)]]
        pairs = align(reference, observed)
        self.assertEqual([p['index'] for p in pairs], list(range(7)))
        self.assertEqual(pairs[0]['start'], 0)
        self.assertEqual(pairs[1]['start'], .92)
        self.assertEqual(pairs[1]['end'], pairs[2]['start'])
        self.assertEqual(pairs[2]['end'], 1.74)
        self.assertTrue(pairs[1]['estimated'])
        self.assertAlmostEqual(sum(p.get('coverage', 1) for p in pairs), len(observed))

    def test_split_recognition_matches_one_source_word(self):
        observed = [dict(word='high', start=.1, end=.3), dict(word='lighting', start=.3, end=.8)]
        pairs = align(['highlighting'], observed)
        self.assertEqual(len(pairs), 1)
        self.assertEqual((pairs[0]['index'], pairs[0]['start'], pairs[0]['end']), (0, .1, .8))
        self.assertEqual(pairs[0]['coverage'], 2)

    def test_joined_words_allow_only_one_spelling_edit(self):
        for source, observed in [('aranges', 'arranges'), ('thecache', 'thecashe'),
                                 ('thecaches', 'thecache'), ('highlighting', 'highlighting')]:
            with self.subTest(source=source, observed=observed):
                self.assertIsNotNone(join_cost(source, observed))
        for source, observed in [('aranges', 'arrows'), ('an', 'and'), ('thecache', 'elsewhere')]:
            with self.subTest(source=source, observed=observed):
                self.assertIsNone(join_cost(source, observed))

    def test_local_alignment_still_skips_unspoken_source_prefix(self):
        pairs = align(['previous', 'sentence', 'a', 'quiet', 'garden'],
                      [dict(word='quiet', start=0, end=.3), dict(word='garden', start=.3, end=.8)])
        self.assertEqual([p['index'] for p in pairs], [3, 4])

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

    def test_complete_clip_includes_beginning_beyond_twelve_seconds(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'audio.pcm'
            path.write_bytes(b'\0' * (96000 * 20))
            reference = [dict(text=f'word{i}', location=i * 10, length=6) for i in range(100)]
            request = dict(segment='screen:0', paths=[str(path)], words=reference, offset=0, complete=True)
            def recognize(pcm, offset):
                self.assertEqual(offset, 0)
                self.assertEqual(len(pcm), 96000 * 20)
                return {}, [dict(word=f'word{i}', start=i * .1, end=(i+1) * .1) for i in range(100)], .01
            timings = Tracker().update(request, recognize)
            self.assertEqual(len(timings), 100)
            self.assertEqual(timings[0]['location'], 0)
            self.assertEqual(timings[-1]['location'], 990)

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
