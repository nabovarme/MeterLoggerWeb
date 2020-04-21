/**
 * @fileoverview Assertions that chai doesn't provide out of the box.
 */

var assertDeepCloseTo = function(actualArray, expectedArray, epsilon) {
  assert.isArray(actualArray);
  assert.isArray(expectedArray);
  for (var i = 0; i < actualArray.length; i++) {
    assert.closeTo(actualArray[i], expectedArray[i], epsilon);
  }
};
