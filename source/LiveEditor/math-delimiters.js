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
  const rest = line.slice(leading.length);
  const trailing = rest.match(/\s*$/)?.[0] ?? '';
  const body = trailing ? rest.slice(0, -trailing.length) : rest;
  if (body.startsWith(fromOpen) && body.endsWith(fromClose) && body.length > fromOpen.length + fromClose.length) {
    return leading + openTo + body.slice(fromOpen.length, -fromClose.length) + closeTo + trailing;
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

// remark-math parses display math as a fenced block. Keep the delimiters on
// their own lines and isolate each display block from surrounding paragraphs;
// Markdown documents often use a single newline around \[...\] formulas, which
// otherwise leaves the delimiters inside a paragraph where remark-math treats
// them as ordinary text. Leave code fences and their contents untouched.
export function normalizeMathForPreview(markdown) {
  const dollarMarkdown = transformMathDelimiters(markdown, 'dollar');
  const newline = dollarMarkdown.includes('\r\n') ? '\r\n' : '\n';
  const lines = dollarMarkdown.replace(/\r\n/g, '\n').split('\n');
  const hasFinalNewline = dollarMarkdown.endsWith('\n');
  if (hasFinalNewline) lines.pop();
  const normalized = [];
  let fence = null;
  const pushDisplayBlock = (block, nextLine) => {
    if (normalized.length && normalized[normalized.length - 1].trim()) normalized.push('');
    normalized.push(...block);
    if (nextLine?.trim()) normalized.push('');
  };

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const fenceMatch = line.match(/^\s{0,3}(`{3,}|~{3,})/);
    if (fenceMatch) {
      const marker = fenceMatch[1];
      if (!fence) fence = {char: marker[0], length: marker.length};
      else if (marker[0] === fence.char && marker.length >= fence.length) fence = null;
      normalized.push(line);
      continue;
    }
    if (fence) {
      normalized.push(line);
      continue;
    }

    const singleLineBlock = line.match(/^(\s{0,3})\$\$(.+?)\$\$\s*$/);
    if (singleLineBlock && singleLineBlock[2].trim()) {
      const prefix = singleLineBlock[1];
      pushDisplayBlock([`${prefix}$$`, singleLineBlock[2].trim(), `${prefix}$$`], lines[i + 1]);
      continue;
    }

    if (line.trim() === '$$') {
      let close = i + 1;
      while (close < lines.length && lines[close].trim() !== '$$') close++;
      if (close < lines.length) {
        pushDisplayBlock(lines.slice(i, close + 1), lines[close + 1]);
        i = close;
        continue;
      }
    }

    normalized.push(line);
  }

  return normalized.join(newline) + (hasFinalNewline ? newline : '');
}
