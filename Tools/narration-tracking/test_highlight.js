const assert=require('node:assert/strict');
const {highlightRange}=require('./highlight');
const result={sentence_starts:[0,6],reference_words:10,words:Array.from({length:10},(_,index)=>({index,start:index}))};
assert.deepEqual(highlightRange(result,0,'3'),[0,3]);
assert.deepEqual(highlightRange(result,3.2,'3'),[2,5]);
assert.deepEqual(highlightRange(result,5.9,'3'),[3,6]);
assert.deepEqual(highlightRange(result,6,'3'),[6,9]);
assert.deepEqual(highlightRange(result,9,'5'),[6,10]);
assert.deepEqual(highlightRange(result,3,'2'),[3,5]);
assert.deepEqual(highlightRange(result,3,'sentence'),[0,6]);
assert.deepEqual(highlightRange(result,8,'sentence'),[6,10]);
assert.deepEqual(highlightRange(result,1,'3'),[0,3]); // seeking back resets position
assert.equal(highlightRange(result,-1,'3'),null);
const irregular={sentence_starts:[0],reference_words:4,words:[{index:0,start:1},{index:2,start:3},{index:3,start:2}]};
assert.equal(highlightRange(irregular,0,'3'),null);
assert.deepEqual(highlightRange(irregular,2.5,'2'),[0,2]);
assert.deepEqual(highlightRange(irregular,3,'2'),[2,4]);
console.log('PASS: small word groups, sentence bounds, seeking, missing timestamps and nonmonotonic estimates');
