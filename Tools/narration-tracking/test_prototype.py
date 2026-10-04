import unittest
from prototype import align, words, wav_bytes
import array, io, wave


def recognized(text):
    return [dict(word=w, start=i, end=i+0.5) for i,(w,_,_) in enumerate(words(text))]


class MatchingTests(unittest.TestCase):
    def test_error_does_not_shift_following_words(self):
        ref=[w[0] for w in words('the coordinator checks the checksum before committing')]
        pairs=align(ref,recognized('the coordinator checks the chess sum before committing'))
        self.assertEqual([p['index'] for p in pairs], [0,1,2,3,5,6])

    def test_repeated_phrase_uses_earliest_allowed_occurrence(self):
        ref=[w[0] for w in words('check the cache then retry check the cache then stop')]
        self.assertEqual([p['index'] for p in align(ref,recognized('check the cache'))],[0,1,2])
        self.assertEqual([p['index'] for p in align(ref,recognized('check the cache'),lower=5)],[5,6,7])

    def test_deleted_word_and_window_prefix(self):
        ref=[w[0] for w in words('before the transaction coordinator writes a checkpoint after checking')]
        self.assertEqual([p['index'] for p in align(ref,recognized('coordinator writes checkpoint after'))],[3,4,6,7])

    def test_no_matches_not_invented(self):
        self.assertEqual(align(['cache','worker'],recognized('unrelated speech')),[])
        self.assertEqual(align([],recognized('hello')),[])

    def test_audio_conversion_preserves_duration(self):
        pcm=array.array('f',[0.1]*24000).tobytes()
        with wave.open(io.BytesIO(wav_bytes(pcm))) as f:
            self.assertEqual((f.getframerate(),f.getnframes(),f.getsampwidth()),(16000,16000,2))

if __name__=='__main__':unittest.main()
