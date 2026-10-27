const isEscaped = (text, index) => {
  let slashes = 0;
  while (index > 0 && text[--index] === '\\') slashes++;
  return slashes % 2 === 1;
};

function transformInline(line, target) {
  let out = '', index = 0;
  while (index < line.length) {
    if (line[index] === '`') {
      let end = index + 1;
      while (line[end] === '`') end++;
      const ticks = line.slice(index, end);
      const close = line.indexOf(ticks, end);
      if (close >= 0) { out += line.slice(index, close + ticks.length); index = close + ticks.length; continue; }
    }
    const latexOpen = line.startsWith('\\(', index) && !isEscaped(line, index);
    const dollarOpen = line[index] === '$' && line[index + 1] !== '$' && !isEscaped(line, index);
    if ((target === 'dollar' && latexOpen) || (target === 'latex' && dollarOpen)) {
      const openingLength = latexOpen ? 2 : 1;
      const closing = latexOpen ? '\\)' : '$';
      let close = index + openingLength;
      while ((close = line.indexOf(closing, close)) >= 0 && isEscaped(line, close)) close++;
      if (close >= 0 && close > index + openingLength) {
        out += (target === 'dollar' ? '$' : '\\(') + line.slice(index + openingLength, close) +
          (target === 'dollar' ? '$' : '\\)');
        index = close + closing.length;
        continue;
      }
    }
    out += line[index++];
  }
  return out;
}

function transformSingleLineBlock(line, fromOpen, fromClose, openTo, closeTo) {
  const leading = line.match(/^\s*/)?.[0] ?? '';
  const body = line.slice(leading.length);
  if (body.startsWith(fromOpen) && body.endsWith(fromClose) && body.length > fromOpen.length + fromClose.length) {
    return leading + openTo + body.slice(fromOpen.length, -fromClose.length) + closeTo;
  }
  return null;
}

export function transformMathDelimiters(markdown, target = 'dollar') {
  const lines = markdown.split(/(?<=\n)/);
  let fence = null, display = null;
  return lines.map(lineWithEnding => {
    const ending = lineWithEnding.endsWith('\r\n') ? '\r\n' : lineWithEnding.endsWith('\n') ? '\n' : '';
    const line = ending ? lineWithEnding.slice(0, -ending.length) : lineWithEnding;
    const fenceMatch = line.match(/^\s{0,3}(`{3,}|~{3,})/);
    if (fenceMatch && !display) {
      const marker = fenceMatch[1];
      if (!fence) fence = {char: marker[0], length: marker.length};
      else if (marker[0] === fence.char && marker.length >= fence.length) fence = null;
      return lineWithEnding;
    }
    if (fence) return lineWithEnding;

    if (display) {
      const closeFrom = display === 'dollar' ? '$$' : '\\]';
      const closeTo = target === 'dollar' ? '$$' : '\\]';
      if (line.trim() === closeFrom) {
        display = null;
        const prefix = line.match(/^\s*/)?.[0] ?? '';
        return prefix + closeTo + ending;
      }
      return lineWithEnding;
    }

    const trimmed = line.trim();
    if (trimmed === '$$') {
      display = 'dollar';
      const prefix = line.match(/^\s*/)?.[0] ?? '';
      return prefix + (target === 'dollar' ? '$$' : '\\[') + ending;
    }
    if (trimmed === '\\[') {
      display = 'latex';
      const prefix = line.match(/^\s*/)?.[0] ?? '';
      return prefix + (target === 'dollar' ? '$$' : '\\[') + ending;
    }
    const dollarBlock = transformSingleLineBlock(line, '$$', '$$', target === 'dollar' ? '$$' : '\\[', target === 'dollar' ? '$$' : '\\]');
    if (dollarBlock !== null) return dollarBlock + ending;
    const latexBlock = transformSingleLineBlock(line, '\\[', '\\]', target === 'dollar' ? '$$' : '\\[', target === 'dollar' ? '$$' : '\\]');
    if (latexBlock !== null) return latexBlock + ending;
    return transformInline(line, target) + ending;
  }).join('');
}
