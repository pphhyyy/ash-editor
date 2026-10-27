import { highlightSyntax, highlightMark, highlightInput } from './highlight.js';
import { HighlightStyle, syntaxHighlighting } from '@codemirror/language';
import { tags } from '@lezer/highlight';
import { CrepeBuilder } from '@milkdown/crepe/builder';
import { codeMirror } from '@milkdown/crepe/feature/code-mirror';
import { latex } from '@milkdown/crepe/feature/latex';
import { table } from '@milkdown/crepe/feature/table';
import { listItem } from '@milkdown/crepe/feature/list-item';
import { cursor } from '@milkdown/crepe/feature/cursor';
import { historyProviderConfig } from '@milkdown/kit/plugin/history';
import { editorViewCtx, parserCtx, remarkCtx, remarkPluginsCtx, InitReady } from '@milkdown/kit/core';
import { imageSchema } from '@milkdown/kit/preset/commonmark';
import { $nodeSchema, $view, $prose, replaceAll } from '@milkdown/kit/utils';
import { Slice } from '@milkdown/kit/prose/model';
import { ViewPlugin as CMViewPlugin, Decoration as CMDecoration } from '@codemirror/view';
import { StateEffect as CMStateEffect } from '@codemirror/state';
import { Decoration, DecorationSet } from '@milkdown/kit/prose/view';
import { Plugin, PluginKey, TextSelection } from '@milkdown/kit/prose/state';
import '@milkdown/crepe/theme/common/style.css';
import '@milkdown/crepe/theme/classic.css';
import './style.css';
import { normalizeClipboardMathDelimiters, normalizeMathForPreview, transformMathDelimiters } from './math-delimiters.js';

// Markdown remains the source of truth outside this editable ProseMirror document.
// No HTML from a document is executed, and no CDN or remote service is used.
let editor, epoch = 0, lastSent = '', updating = false, ready = false;
let lastNativeSource = '', edited = false, composing = false;
let mathDelimiter = 'dollar';
const post = payload => window.webkit?.messageHandlers?.ashEditor?.postMessage(payload);
const escapeHTML = value => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
const imageLayoutMarker = /(?:^|\s)\[ASH:(width=\d+|align=left)\]$/i;
const minImageWidth = 64;
const maxImageWidth = 4096;
let activeImageMenuCloser = null;

function imageTitleDetails(title) {
  let value = String(title || ''), width = 0, align = 'center';
  let match;
  while ((match = value.match(imageLayoutMarker))) {
    if (/^width=/i.test(match[1])) {
      width = Math.max(minImageWidth, Math.min(maxImageWidth, Number(match[1].slice(6)) || minImageWidth));
    } else if (/^align=left$/i.test(match[1])) align = 'left';
    value = value.slice(0, match.index).trimEnd();
  }
  return {title:value, width, align};
}

function imageTitleWithLayout(title, changes = {}) {
  const current = imageTitleDetails(title);
  const next = {...current, ...changes};
  const markers = [];
  if (next.width) markers.push(`[ASH:width=${Math.max(minImageWidth, Math.min(maxImageWidth, Math.round(next.width)))}]`);
  if (next.align === 'left') markers.push('[ASH:align=left]');
  return [current.title, ...markers].filter(Boolean).join(' ');
}

function imageRenderSource(source) {
  if (!source || source.startsWith('ash-image://') || /^(?:data:|blob:|https?:)/i.test(source)) return source;
  return `ash-image://render?src=${encodeURIComponent(source)}`;
}

function containsLatexMath(markdown) {
  const lines = markdown.split(/\r?\n/);
  let fence = null;
  const outsideCode = [];
  for (const line of lines) {
    const match = line.match(/^\s{0,3}(`{3,}|~{3,})/);
    if (match) {
      const marker = match[1];
      if (!fence) fence = {char:marker[0], length:marker.length};
      else if (marker[0] === fence.char && marker.length >= fence.length) fence = null;
      continue;
    }
    if (!fence) outsideCode.push(line);
  }
  const source = outsideCode.join('\n');
  const isEscaped = (text, index) => {
    let slashes = 0;
    while (index > 0 && text[--index] === '\\') slashes++;
    return slashes % 2 === 1;
  };
  for (const [open, close] of [['\\[','\\]'], ['\\(','\\)']]) {
    let start = source.indexOf(open);
    while (start >= 0) {
      if (!isEscaped(source, start)) {
        let end = source.indexOf(close, start + open.length);
        while (end >= 0 && isEscaped(source, end)) end = source.indexOf(close, end + close.length);
        if (end >= 0) return true;
      }
      start = source.indexOf(open, start + open.length);
    }
  }
  return false;
}

function clipboardPlainText(clipboard) {
  // WebKit can expose AppKit pasteboard values under their native UTI names
  // instead of MIME names. In that case Milkdown sees rich HTML, but a
  // text/plain-only check misses the Markdown formula source entirely.
  for (const type of ['text/plain', 'text/markdown', 'public.utf8-plain-text', 'NSStringPboardType', 'public.utf16-external-plain-text']) {
    const value = clipboard?.getData(type);
    if (value) return value;
  }
  return '';
}

function pasteMathMarkdown(markdown) {
  const clipboardMarkdown = normalizeClipboardMathDelimiters(markdown);
  const source = normalizeMathForPreview(transformMathDelimiters(clipboardMarkdown, mathDelimiter));
  editor.editor.action(ctx => {
    const view = ctx.get(editorViewCtx);
    const parsed = ctx.get(parserCtx)(source);
    if (!parsed) return;
    view.dispatch(view.state.tr.replaceSelection(new Slice(parsed.content, 0, 0)).scrollIntoView());
    view.focus();
  });
}

function installImageHandling(editable) {
  const rewriteImage = image => {
    const source = image.getAttribute('src') || '';
    if (!source || source.startsWith('ash-image://') || /^(?:data:|blob:|https?:)/i.test(source)) return;
    if (!image.dataset.ashImageSource || image.dataset.ashImageSource !== source) {
      image.dataset.ashImageSource = source;
      image.setAttribute('src', imageRenderSource(source));
    }
  };
  const rewriteAll = () => document.querySelectorAll('.ProseMirror img[src]').forEach(rewriteImage);
  new MutationObserver(records => {
    for (const record of records) {
      if (record.type === 'attributes' && record.target instanceof HTMLImageElement) rewriteImage(record.target);
      for (const node of record.addedNodes) {
        if (node instanceof HTMLImageElement) rewriteImage(node);
        node.querySelectorAll?.('img[src]').forEach(rewriteImage);
      }
    }
  }).observe(editable, {subtree:true, childList:true, attributes:true, attributeFilter:['src']});
  rewriteAll();
  document.addEventListener('paste', event => {
    if (!editable.contains(event.target) || !editable.isContentEditable) return;
    const clipboard = event.clipboardData;
    const isImageType = type => {
      const value = String(type || '').toLowerCase();
      return value.startsWith('image/') || ['public.png', 'public.jpeg', 'public.tiff'].includes(value);
    };
    const items = [...(clipboard?.items || [])];
    const files = [...(clipboard?.files || [])];
    const containsImage = items.some(item => isImageType(item.type)) || files.some(file => isImageType(file.type)) ||
      [...(clipboard?.types || [])].some(isImageType);
    if (containsImage) {
      event.preventDefault();
      event.stopImmediatePropagation();
      post({type:'pasteImage'});
      return;
    }
    const text = normalizeClipboardMathDelimiters(clipboardPlainText(clipboard));
    if (!containsLatexMath(text)) return;
    // Rich clipboard HTML often contains the literal Markdown delimiters as
    // text nodes. Parse the plain-text Markdown after normalizing it so pasted
    // TeX uses the same preview pipeline as a document opened from disk.
    event.preventDefault();
    event.stopImmediatePropagation();
    pasteMathMarkdown(text);
  }, true);
}

const imageView = $view(imageSchema.node, () => (initialNode, view, getPos) => {
  let node = initialNode;
  const dom = document.createElement('span');
  dom.className = 'ash-image-wrapper';
  dom.contentEditable = 'false';
  dom.draggable = true;

  const image = document.createElement('img');
  image.alt = node.attrs.alt || '';
  image.src = imageRenderSource(node.attrs.src || '');
  image.dataset.ashImageSource = node.attrs.src || '';
  const handle = document.createElement('button');
  handle.type = 'button';
  handle.className = 'ash-image-resize-handle';
  handle.setAttribute('aria-label', '调整图片大小');
  handle.title = '拖动调整图片大小';
  handle.innerHTML = '<span aria-hidden="true"></span>';
  dom.append(image, handle);

  const menu = document.createElement('div');
  menu.className = 'ash-image-context-menu';
  menu.setAttribute('role', 'menu');
  menu.hidden = true;
  const menuItems = new Map();
  for (const [align, label] of [['center', '居中显示'], ['left', '左对齐']]) {
    const item = document.createElement('button');
    item.type = 'button';
    item.setAttribute('role', 'menuitemradio');
    item.textContent = label;
    item.addEventListener('click', event => {
      event.preventDefault();
      event.stopPropagation();
      persistAlignment(align);
      closeMenu(true);
    });
    menuItems.set(align, item);
    menu.append(item);
  }

  let drag = null;
  const refresh = () => {
    const details = imageTitleDetails(node.attrs.title);
    const source = node.attrs.src || '';
    if (image.dataset.ashImageSource !== source) {
      image.dataset.ashImageSource = source;
      image.src = imageRenderSource(source);
    }
    if (image.alt !== (node.attrs.alt || '')) image.alt = node.attrs.alt || '';
    if (image.title !== details.title) image.title = details.title;
    image.style.width = details.width ? `${details.width}px` : '';
    dom.dataset.ashAlign = details.align;
    for (const [align, item] of menuItems) item.setAttribute('aria-checked', String(details.align === align));
  };
  const persistWidth = width => {
    const pos = getPos();
    if (typeof pos !== 'number') return;
    const current = view.state.doc.nodeAt(pos);
    if (!current || current.type !== node.type) return;
    const title = imageTitleWithLayout(current.attrs.title, {width});
    if (title !== current.attrs.title) {
      view.dispatch(view.state.tr.setNodeMarkup(pos, undefined, {...current.attrs, title}));
    }
  };
  const persistAlignment = align => {
    const pos = getPos();
    if (typeof pos !== 'number') return;
    const current = view.state.doc.nodeAt(pos);
    if (!current || current.type !== node.type) return;
    const title = imageTitleWithLayout(current.attrs.title, {align});
    if (title !== current.attrs.title) {
      view.dispatch(view.state.tr.setNodeMarkup(pos, undefined, {...current.attrs, title}));
    }
  };
  const closeMenu = (restoreEditorFocus = false) => {
    menu.remove();
    document.removeEventListener('pointerdown', onOutsidePointerDown, true);
    document.removeEventListener('keydown', onMenuKeyDown, true);
    window.removeEventListener('resize', onWindowResize);
    if (activeImageMenuCloser === closeMenu) activeImageMenuCloser = null;
    if (restoreEditorFocus) view.dom.focus({preventScroll:true});
  };
  const onWindowResize = () => closeMenu();
  const onOutsidePointerDown = event => { if (!menu.contains(event.target)) closeMenu(); };
  const onMenuKeyDown = event => {
    if (event.key !== 'Escape') return;
    event.preventDefault();
    event.stopPropagation();
    closeMenu(true);
  };
  const showMenu = event => {
    activeImageMenuCloser?.();
    activeImageMenuCloser = closeMenu;
    refresh();
    document.body.append(menu);
    menu.hidden = false;
    const x = Math.max(8, Math.min(event.clientX, window.innerWidth - menu.offsetWidth - 8));
    const y = Math.max(8, Math.min(event.clientY, window.innerHeight - menu.offsetHeight - 8));
    menu.style.left = `${x}px`;
    menu.style.top = `${y}px`;
    document.addEventListener('pointerdown', onOutsidePointerDown, true);
    document.addEventListener('keydown', onMenuKeyDown, true);
    window.addEventListener('resize', onWindowResize);
    menuItems.get(imageTitleDetails(node.attrs.title).align)?.focus({preventScroll:true});
  };
  dom.addEventListener('contextmenu', event => {
    if (!image.contains(event.target)) return;
    event.preventDefault();
    event.stopPropagation();
    showMenu(event);
  });
  const stop = event => { event.preventDefault(); event.stopPropagation(); };
  handle.addEventListener('pointerdown', event => {
    if (event.button !== 0) return;
    const bounds = image.getBoundingClientRect();
    if (!bounds.width) return;
    stop(event);
    drag = {pointerId:event.pointerId, startX:event.clientX, startWidth:bounds.width, width:bounds.width, moved:false};
    dom.classList.add('ash-image-resizing');
    try { handle.setPointerCapture(event.pointerId); } catch {}
  });
  handle.addEventListener('pointermove', event => {
    if (!drag || drag.pointerId !== event.pointerId) return;
    stop(event);
    const available = view.dom.clientWidth || maxImageWidth;
    const width = Math.max(minImageWidth, Math.min(maxImageWidth, available, drag.startWidth + event.clientX - drag.startX));
    drag.width = Math.round(width);
    drag.moved ||= Math.abs(width - drag.startWidth) >= 1;
    image.style.width = `${drag.width}px`;
  });
  const finishResize = event => {
    if (!drag || (event?.pointerId !== undefined && drag.pointerId !== event.pointerId)) return;
    const finished = drag;
    drag = null;
    dom.classList.remove('ash-image-resizing');
    if (finished.moved) persistWidth(finished.width);
  };
  handle.addEventListener('pointerup', finishResize);
  handle.addEventListener('pointercancel', finishResize);
  handle.addEventListener('click', event => { event.preventDefault(); event.stopPropagation(); });
  handle.addEventListener('keydown', event => {
    if (!['ArrowLeft', 'ArrowRight'].includes(event.key)) return;
    stop(event);
    const current = image.getBoundingClientRect().width;
    const step = event.shiftKey ? 50 : 10;
    const width = current + (event.key === 'ArrowRight' ? step : -step);
    image.style.width = `${Math.max(minImageWidth, Math.min(maxImageWidth, view.dom.clientWidth || maxImageWidth, width))}px`;
    persistWidth(Number.parseFloat(image.style.width));
  });
  refresh();

  return {
    dom,
    update(next) {
      if (next.type !== node.type) return false;
      node = next;
      refresh();
      return true;
    },
    selectNode() { dom.classList.add('ash-image-selected'); },
    deselectNode() { dom.classList.remove('ash-image-selected'); },
    stopEvent(event) { return event.target === handle || handle.contains(event.target); },
    ignoreMutation() { return true; },
    destroy() { closeMenu(); },
  };
});

const detailsSyntax = ctx => async () => {
  await ctx.wait(InitReady);
  const plugin = {plugin: () => tree => {
    const processor = ctx.get(remarkCtx);
    const paragraph = () => ({type:'paragraph', children:[]});
    const parseBody = source => {
      if (!source.trim()) return [];
      const nodes = processor.parse(source.trim()).children;
      return nodes.length ? nodes : [];
    };
    const summaryOf = html => {
      const match = html.match(/<summary\b[^>]*>([\s\S]*?)<\/summary\s*>/i);
      if (!match) return '详细内容';
      const text = new DOMParser().parseFromString(match[1], 'text/html').body.textContent?.trim();
      return text || '详细内容';
    };
    function convert(parent) {
      if (!parent.children) return;
      for (let i = 0; i < parent.children.length; i++) {
        const node = parent.children[i];
        if (node.type === 'html' && /^\s*<details(?:\s[^>]*)?>/i.test(node.value)) {
          const opening = node.value;
          const openingMatch = opening.match(/^\s*<details(?:\s[^>]*)?>/i);
          const summaryMatch = opening.match(/<summary\b[^>]*>[\s\S]*?<\/summary\s*>/i);
          const bodyStart = summaryMatch ? summaryMatch.index + summaryMatch[0].length
            : openingMatch[0].length;
          const tail = opening.slice(bodyStart);
          const closedInPlace = /<\/details>/i.test(tail);
          let end = i, closed = closedInPlace;
          const children = parseBody(closedInPlace ? tail.replace(/<\/details>[\s\S]*$/i, '') : tail);
          if (!closedInPlace) {
            for (let j = i + 1; j < parent.children.length; j++) {
              const next = parent.children[j];
              end = j;
              if (next.type === 'html' && /<\/details>/i.test(next.value)) {
                const body = next.value.replace(/<\/details>[\s\S]*$/i, '');
                children.push(...parseBody(body));
                closed = true;
                break;
              }
              children.push(next);
            }
          }
          if (!closed) continue;
          const details = {
            type: 'ashDetails',
            summary: summaryOf(opening),
            open: /^\s*<details[^>]*\bopen\b/i.test(opening),
            children: children.length ? children : [paragraph()],
          };
          parent.children.splice(i, end - i + 1, details);
          convert(details);
          continue;
        }
        convert(node);
      }
    }
    convert(tree);
  }, options:{}};
  // Before commonmark wraps standalone HTML in paragraph nodes.
  ctx.update(remarkPluginsCtx, plugins => [plugin, ...plugins]);
  return () => ctx.update(remarkPluginsCtx, plugins => plugins.filter(item => item !== plugin));
};

const detailsNode = $nodeSchema('ash_details', ctx => ({
  group: 'block', content: 'block+', defining: true,
  attrs: { summary: { default: '详细内容' }, open: { default: false } },
  parseDOM: [{ tag: 'details', getAttrs: dom => ({summary: dom.querySelector('summary')?.textContent || '详细内容', open: dom.open}), contentElement: '[data-details-body]' }],
  toDOM: node => ['details', node.attrs.open ? {open:''} : {}, ['summary', {}, node.attrs.summary], ['div', {'data-details-body':''}, 0]],
  parseMarkdown: {
    match: node => node.type === 'ashDetails',
    runner: (state, node, type) => { state.openNode(type, {summary: node.summary, open: node.open}); state.next(node.children); state.closeNode(); },
  },
  toMarkdown: {
    match: node => node.type.name === 'ash_details',
    runner: (state, node) => {
      // Serialize the body through the outer serializer. Starting a nested
      // SerializerState on the shared remark processor corrupts its buffer
      // (or empties the stack) whenever the details body contains formatting.
      state.addNode('html', undefined, `<details${node.attrs.open ? ' open' : ''}>\n<summary>${escapeHTML(node.attrs.summary)}</summary>`);
      state.next(node.content);
      state.addNode('html', undefined, '</details>');
    },
  },
}));

const detailsView = $view(detailsNode.node, () => (node, view, getPos) => {
  const dom = document.createElement('details'); dom.open = node.attrs.open;
  const summary = document.createElement('summary');
  const label = document.createElement('span'); label.contentEditable = 'true'; label.textContent = node.attrs.summary;
  label.setAttribute('aria-label', '折叠框标题');
  summary.append(label);
  const contentDOM = document.createElement('div'); contentDOM.dataset.detailsBody = '';
  dom.append(summary, contentDOM);
  label.addEventListener('input', () => {
    const pos = getPos(); if (typeof pos !== 'number') return;
    view.dispatch(view.state.tr.setNodeMarkup(pos, undefined, {...node.attrs, summary: label.textContent}));
  });
  // Opening a fold is view state, not a document edit.
  return {
    dom, contentDOM,
    update(next) { if (next.type !== node.type) return false; node = next; if (label.textContent !== next.attrs.summary) label.textContent = next.attrs.summary; return true; },
    stopEvent(event) { return event.target === label || label.contains(event.target); },
    ignoreMutation(mutation) { return mutation.target === dom || summary.contains(mutation.target); },
  };
});

function flush() {
  if (!ready || updating) return lastNativeSource;
  // Preserve original whitespace until an actual edit; opening / viewing a file never dirties it.
  const markdown = edited ? transformMathDelimiters(editor.getMarkdown(), mathDelimiter) : lastNativeSource;
  if (markdown !== lastSent) {
    lastSent = markdown;
    post({type:'change', markdown, epoch});
  }
  return markdown;
}

function replaceDocumentWithoutHistory(markdown) {
  editor.editor.action(ctx => {
    const view = ctx.get(editorViewCtx);
    const parsed = ctx.get(parserCtx)(markdown);
    if (!parsed) return;
    const previousSelection = view.state.selection;
    let transaction = view.state.tr.replaceWith(0, view.state.doc.content.size, parsed.content);
    if (previousSelection instanceof TextSelection) {
      const limit = transaction.doc.content.size;
      const anchor = Math.min(previousSelection.anchor, limit);
      const head = Math.min(previousSelection.head, limit);
      transaction = transaction.setSelection(TextSelection.create(transaction.doc, anchor, head));
    }
    view.dispatch(transaction.setMeta('addToHistory', false));
  });
}

const syncPlugin = $prose(() => new Plugin({
  view: () => ({update(view, previous) {
    if (ready && !view.state.doc.eq(previous.doc) && !updating) {
      edited = true;
      if (!composing && !view.composing) flush();
    }
  }}),
  props: { handleDOMEvents: {
    focus: () => { post({type:'focus'}); return false; },
    blur: () => { queueMicrotask(flush); return false; },
    compositionstart: () => { composing = true; return false; },
    compositionend: () => { composing = false; setTimeout(flush, 0); return false; },
  } },
}));


// Decorations affect display only. They never enter Markdown serialization or undo history.
let fadeGeneration = 0;
let fadeOptions = {active:false, opacity:0.35, duration:4, ink:'#383047'};
// Animate paint only. Dispatching editor transactions every 60 ms rewrites the
// selection DOM and can make WebKit scroll the active line to the viewport top.
function fadeStyle(birth, rgb) {
  // Keep each inserted span's style stable across editor transactions. Updating
  // a negative animation delay on every keystroke restarts CSS animation and
  // makes fading appear tied to typing speed. The birth marker also keeps
  // adjacent edits from being coalesced into one span with a restarted clock.
  return '--ash-fade-birth:'+birth+';--ash-fade-color:rgb('+rgb.join(',')+');--ash-fade-opacity:'+fadeOptions.opacity+
    ';animation:ash-text-fade '+fadeOptions.duration+'s linear 0s both';
}
const fadeKey = new PluginKey('ash-fade');
const fadePlugin = $prose(() => new Plugin({
  key: fadeKey,
  state: {
    init: () => [],
    apply(tr, previous) {
      if (!fadeOptions.active || updating || tr.getMeta('ashFadeReset')) return [];
      const now = performance.now();
      const entries = previous.map(item => ({...item, from:tr.mapping.map(item.from,1), to:tr.mapping.map(item.to,-1)}))
        .filter(item => item.to > item.from && now-item.birth < fadeOptions.duration*1000);
      tr.mapping.maps.forEach((map,index) => map.forEach((_a,_b,from,to) => {
        const rest = tr.mapping.slice(index+1);
        from = rest.map(from,1); to = rest.map(to,-1);
        if (to <= from) return;
        tr.doc.nodesBetween(from,to,(node,pos) => {
          if (node.isText) entries.push({from:Math.max(from,pos),to:Math.min(to,pos+node.nodeSize),birth:now});
        });
      }));
      return entries;
    }
  },
  props: { decorations(state) {
    if (!fadeOptions.active) return null;
    const hex = fadeOptions.ink.replace('#','');
    const rgb = [0,2,4].map(i => parseInt(hex.slice(i,i+2),16));
    return DecorationSet.create(state.doc, fadeKey.getState(state).filter(item => item.to > item.from).map(item => {
      return Decoration.inline(item.from,item.to,{class:'ash-fading-char',style:fadeStyle(item.birth,rgb)});
    }));
  } }
}));


const fadeClock = CMStateEffect.define();
const codeFadePlugin = CMViewPlugin.fromClass(class {
  constructor(view) {
    this.view = view; this.spans = []; this.decorations = CMDecoration.none; this.generation = fadeGeneration;
    this.timer = setInterval(() => {
      if (this.generation !== fadeGeneration) view.dispatch({effects:fadeClock.of(null)});
    },60);
  }
  update(update) {
    if (this.generation !== fadeGeneration || !fadeOptions.active || updating) {
      this.spans = []; this.generation = fadeGeneration;
    }
    if (fadeOptions.active && update.docChanged && !updating) {
      this.spans = this.spans.map(span => ({...span,from:update.changes.mapPos(span.from,1),to:update.changes.mapPos(span.to,-1)}));
      update.changes.iterChangedRanges((_a,_b,from,to) => {
        if (to > from) this.spans.push({from,to,birth:performance.now()});
      });
    }
    const now=performance.now(), hex=fadeOptions.ink.replace('#','');
    const rgb=[0,2,4].map(i=>parseInt(hex.slice(i,i+2),16));
    this.spans=this.spans.filter(span=>span.to>span.from && now-span.birth < fadeOptions.duration*1000);
    this.decorations=CMDecoration.set(this.spans.map(span=> {
      return CMDecoration.mark({class:'ash-fading-char',attributes:{style:fadeStyle(span.birth,rgb)}}).range(span.from,span.to);
    }),true);
  }
  destroy() { clearInterval(this.timer); }
},{decorations:value=>value.decorations});

const codeColors = syntaxHighlighting(HighlightStyle.define([
  {tag:[tags.keyword,tags.operatorKeyword],color:'var(--ash-syntax-keyword)'},
  {tag:[tags.string,tags.regexp],color:'var(--ash-syntax-string)'},
  {tag:[tags.number,tags.bool,tags.null],color:'var(--ash-syntax-number)'},
  {tag:[tags.comment,tags.meta],color:'var(--ash-muted)'},
  {tag:[tags.function(tags.variableName),tags.typeName,tags.className],color:'var(--ash-syntax-function)'},
]));
async function start(config) {
  mathDelimiter = config.mathDelimiter || 'dollar';
  epoch = config.epoch;
  lastNativeSource = transformMathDelimiters(config.markdown, mathDelimiter);
  lastSent = lastNativeSource;
  const parseSource = normalizeMathForPreview(lastNativeSource);
  window.ashParseSource = parseSource;
  editor = new CrepeBuilder({root: '#editor', defaultValue: parseSource})
    .addFeature(codeMirror, {extensions:[codeFadePlugin,codeColors], searchPlaceholder:'搜索语言', copyText:'复制', noResultText:'无匹配语言', previewOnlyByDefault:true})
    .addFeature(table)
    .addFeature(listItem)
    .addFeature(latex, {katexOptions:{throwOnError:false, strict:'ignore'}})
    // WebKit scrolls the editable page when Milkdown's virtual-cursor widget
    // is inserted or removed as a selection changes. Keep the native caret.
    .addFeature(cursor, {virtual:false});
  // Keep the library's transaction-based undo/redo, with bounded history.
  editor.editor.config(ctx => ctx.set(historyProviderConfig.key, {depth:500, newGroupDelay:500}));
  editor.setReadonly(Boolean(config.readOnly));
  editor.editor.use(highlightSyntax).use(highlightMark).use(highlightInput);
  editor.editor.use(detailsNode).use(detailsSyntax).use(detailsView).use(imageView).use(syncPlugin).use(fadePlugin);
  await editor.create();
  ready = true;
  const editable = document.querySelector('.ProseMirror');
  editable.setAttribute('aria-label', '正文：实时预览编辑器');
  editable.setAttribute('role', 'textbox'); editable.setAttribute('aria-multiline', 'true');
  installImageHandling(editable);
  applyAppearance(config);
  post({type:'ready', epoch});
  if (lastNativeSource !== config.markdown) post({type:'change', markdown:lastNativeSource, epoch});
}

let appliedAppearance = '';
function applyAppearance(config) {
  // Native character-count updates also send the current Markdown. Appearance
  // changes alone may touch layout; typing must not repeatedly reset it.
  const appearance = JSON.stringify([config.showTitle, config.title, config.fontSize, config.mathDelimiter,
    config.ink, config.alignment, config.night, config.theme, config.readOnly, config.concealed,
    config.fading, config.fadeOpacity, config.fadeDuration, config.pageMargin]);
  if (appearance === appliedAppearance) return;
  appliedAppearance = appearance;
  mathDelimiter = config.mathDelimiter === 'latex' ? 'latex' : 'dollar';
  editor.setReadonly(Boolean(config.readOnly));
  document.documentElement.dataset.ashTheme = config.night ? 'night' : (config.theme === '纸感' ? 'paper' : 'purple');
  const title = document.querySelector('#document-title');
  title.hidden = !config.showTitle;
  title.readOnly = Boolean(config.readOnly);
  if (document.activeElement !== title && title.value !== config.title) title.value = config.title || '';
  document.documentElement.style.setProperty('--ash-title-space',config.showTitle ? '68px' : '0px');
  const fadeChanged = fadeOptions.active !== Boolean(config.fading) ||
    fadeOptions.opacity !== Number(config.fadeOpacity || 0.35) ||
    fadeOptions.duration !== Number(config.fadeDuration || 4) || fadeOptions.ink !== config.ink;
  if (fadeChanged) fadeGeneration += 1;
  fadeOptions = {active:Boolean(config.fading), opacity:Number(config.fadeOpacity || 0.35), duration:Number(config.fadeDuration || 4), ink:config.ink};
  if (ready && fadeChanged) editor.editor.action(ctx => {
    const view = ctx.get(editorViewCtx);
    view.dispatch(view.state.tr.setMeta('ashFadeReset',true).setMeta('addToHistory',false));
  });
  document.documentElement.style.setProperty('--ash-font-size', `${config.fontSize}px`);
  document.documentElement.style.setProperty('--ash-page-margin', `${Number(config.pageMargin || 0)}px`);
  document.documentElement.style.setProperty('--ash-ink', config.ink);
  document.documentElement.style.setProperty('--ash-align', config.alignment);
  document.documentElement.classList.toggle('night-theme', Boolean(config.night));
  document.body.classList.toggle('concealed', Boolean(config.concealed || config.fading));
}

window.ashEditor = {
  async configure(config) {
    try {
      if (!editor) { await start(config); return; }
      if (!ready) return;
      const oldMathDelimiter = mathDelimiter;
      applyAppearance(config);
      if (oldMathDelimiter !== mathDelimiter && config.epoch === epoch) {
        const currentSource = edited ? editor.getMarkdown() : lastNativeSource;
        lastNativeSource = transformMathDelimiters(currentSource, mathDelimiter);
        const parseSource = normalizeMathForPreview(lastNativeSource);
        updating = true;
        replaceDocumentWithoutHistory(parseSource);
        updating = false;
        edited = false;
        if (lastNativeSource !== lastSent) {
          lastSent = lastNativeSource;
          post({type:'change', markdown:lastNativeSource, epoch});
        }
      }
      if (config.epoch !== epoch) {
        updating = true;
        epoch = config.epoch;
        lastNativeSource = transformMathDelimiters(config.markdown, mathDelimiter);
        lastSent = lastNativeSource; edited = false;
        const parseSource = normalizeMathForPreview(lastNativeSource);
        window.ashParseSource = parseSource;
        editor.editor.action(replaceAll(parseSource, true));
        updating = false;
        if (lastNativeSource !== config.markdown) post({type:'change', markdown:lastNativeSource, epoch});
      }
    } catch (error) { post({type:'error', message:String(error.stack || error)}); }
  },
  flush,
  insertImage(source) {
    if (!ready || !source || !document.querySelector('.ProseMirror')?.isContentEditable) return;
    editor.editor.action(ctx => {
      const view = ctx.get(editorViewCtx);
      const imageType = view.state.schema.nodes.image;
      if (!imageType) return;
      const image = imageType.create({src:source, alt:'剪贴图片', title:''});
      view.dispatch(view.state.tr.replaceSelectionWith(image).scrollIntoView());
      view.focus();
    });
  },
  pasteMarkdown(markdown) {
    const clipboardMarkdown = normalizeClipboardMathDelimiters(markdown);
    if (!ready || !document.querySelector('.ProseMirror')?.isContentEditable || !containsLatexMath(clipboardMarkdown)) return false;
    pasteMathMarkdown(clipboardMarkdown);
    return true;
  },
  focus() { if (ready) editor.editor.action(ctx => ctx.get(editorViewCtx).focus()); },
  // Local-only testability: ProseMirror state and serialized Markdown, not a second editor.
  inspect() { return {markdown:flush(), html:document.querySelector('.ProseMirror')?.innerHTML, epoch}; },
};
window.addEventListener('error', event => post({type:'error', message:event.message}));
window.addEventListener('unhandledrejection', event => post({type:'error', message:String(event.reason)}));
const titleInput = document.querySelector('#document-title');
titleInput.addEventListener('input', () => post({type:'titleChange',title:titleInput.value}));
titleInput.addEventListener('focus', () => post({type:'focus'}));
post({type:'loaded'});
