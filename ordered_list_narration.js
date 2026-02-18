(() => {
  const SMALL_NUMBERS = [
    "zero",
    "one",
    "two",
    "three",
    "four",
    "five",
    "six",
    "seven",
    "eight",
    "nine",
    "ten",
    "eleven",
    "twelve",
    "thirteen",
    "fourteen",
    "fifteen",
    "sixteen",
    "seventeen",
    "eighteen",
    "nineteen"
  ];
  const TENS = [
    "",
    "",
    "twenty",
    "thirty",
    "forty",
    "fifty",
    "sixty",
    "seventy",
    "eighty",
    "ninety"
  ];
  const MAX_ABSOLUTE_VALUE = 999999999999;

  function parseIntegerAttribute(value) {
    if (typeof value !== "string") return null;
    const trimmed = value.trim();
    if (!trimmed) return null;
    if (!/^[+-]?\d+$/.test(trimmed)) return null;

    const parsed = Number.parseInt(trimmed, 10);
    if (!Number.isSafeInteger(parsed)) return null;
    return parsed;
  }

  function resolveOrderedListItemNumber(itemValues, start, isReversed, targetIndex) {
    if (!Array.isArray(itemValues)) return null;
    if (!Number.isSafeInteger(start)) return null;
    if (typeof isReversed !== "boolean") return null;
    if (!Number.isInteger(targetIndex) || targetIndex < 0 || targetIndex >= itemValues.length) {
      return null;
    }

    let current = start;
    for (let i = 0; i < itemValues.length; i += 1) {
      const value = itemValues[i];
      if (value != null) {
        if (!Number.isSafeInteger(value)) return null;
        current = value;
      }

      if (i === targetIndex) {
        return current;
      }

      current += isReversed ? -1 : 1;
      if (!Number.isSafeInteger(current)) return null;
    }

    return null;
  }

  function integerToEnglishCardinal(value) {
    if (!Number.isSafeInteger(value)) return null;
    if (Math.abs(value) > MAX_ABSOLUTE_VALUE) return null;
    if (value === 0) return "zero";
    if (value < 0) {
      const positive = convertPositiveIntegerToEnglish(-value);
      if (!positive) return null;
      return `minus ${positive}`;
    }
    return convertPositiveIntegerToEnglish(value);
  }

  function convertPositiveIntegerToEnglish(value) {
    if (!Number.isSafeInteger(value) || value <= 0) return null;
    if (value < 20) return SMALL_NUMBERS[value];
    if (value < 100) {
      const tensPart = TENS[Math.floor(value / 10)];
      const ones = value % 10;
      return ones === 0 ? tensPart : `${tensPart}-${SMALL_NUMBERS[ones]}`;
    }
    if (value < 1000) {
      const hundreds = Math.floor(value / 100);
      const remainder = value % 100;
      if (remainder === 0) {
        return `${SMALL_NUMBERS[hundreds]} hundred`;
      }
      return `${SMALL_NUMBERS[hundreds]} hundred ${convertPositiveIntegerToEnglish(remainder)}`;
    }
    if (value < 1000000) {
      return combineLargeNumber(value, 1000, "thousand");
    }
    if (value < 1000000000) {
      return combineLargeNumber(value, 1000000, "million");
    }
    return combineLargeNumber(value, 1000000000, "billion");
  }

  function combineLargeNumber(value, scale, scaleLabel) {
    const major = Math.floor(value / scale);
    const remainder = value % scale;
    const majorWords = convertPositiveIntegerToEnglish(major);
    if (!majorWords) return null;
    if (remainder === 0) {
      return `${majorWords} ${scaleLabel}`;
    }
    const remainderWords = convertPositiveIntegerToEnglish(remainder);
    if (!remainderWords) return null;
    return `${majorWords} ${scaleLabel} ${remainderWords}`;
  }

  function buildOrderedListNarrationPrefix(number) {
    const words = integerToEnglishCardinal(number);
    if (!words) return null;
    const capitalized = `${words[0].toUpperCase()}${words.slice(1)}`;
    return `${capitalized}. `;
  }

  const api = {
    parseIntegerAttribute,
    resolveOrderedListItemNumber,
    integerToEnglishCardinal,
    buildOrderedListNarrationPrefix
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }

  if (typeof globalThis !== "undefined") {
    globalThis.ReedahOrderedListNarration = api;
  }
})();
