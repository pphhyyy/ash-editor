import { CrepeBuilder } from '@milkdown/crepe/builder';
import { codeMirror } from '@milkdown/crepe/feature/code-mirror';
import { table } from '@milkdown/crepe/feature/table';
import { listItem } from '@milkdown/crepe/feature/list-item';
import { cursor } from '@milkdown/crepe/feature/cursor';
import { editorViewCtx, remarkCtx, remarkPluginsCtx, InitReady } from '@milkdown/kit/core';
import { $nodeSchema, $view, $prose, replaceAll } from '@milkdown/kit/utils';
import { ViewPlugin as CMViewPlugin, Decoration as CMDecoration } from '@codemirror/view';
import { StateEffect as CMStateEffect } from '@codemirror/state';
import { Decoration, DecorationSet } from '@milkdown/kit/prose/view';
import { Plugin, PluginKey, TextSelection } from '@milkdown/kit/prose/state';
import '@milkdown/crepe/theme/common/style.css';
import '@milkdown/crepe/theme/classic.css';
import './style.css';

// Markdown remains the source of truth outside this editable ProseMirror document.
// No HTML from a document is executed, and no CDN or remote service is used.
let editor, epoch = 0, lastSent = '', updating = false, ready = false;
let lastNativeSource = '', edited = false, composing = false;
const post = payload => window.webkit?.messageHandlers?.ashEditor?.postMessage(payload);
const escapeHTML = value => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

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
  const markdown = edited ? editor.getMarkdown() : lastNativeSource;
  if (markdown !== lastSent) {
    lastSent = markdown;
    post({type:'change', markdown, epoch});
  }
  return markdown;
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

async function start(config) {
  epoch = config.epoch; lastSent = config.markdown; lastNativeSource = config.markdown;
  window.ashParseSource = config.markdown;
  editor = new CrepeBuilder({root: '#editor', defaultValue: config.markdown})
    .addFeature(codeMirror, {extensions:[codeFadePlugin], searchPlaceholder:'搜索语言', copyText:'复制', noResultText:'无匹配语言'})
    .addFeature(table)
    .addFeature(listItem)
    // WebKit scrolls the editable page when Milkdown's virtual-cursor widget
    // is inserted or removed as a selection changes. Keep the native caret.
    .addFeature(cursor, {virtual:false});
  editor.editor.use(detailsNode).use(detailsSyntax).use(detailsView).use(syncPlugin).use(fadePlugin);
  await editor.create();
  ready = true;
  const editable = document.querySelector('.ProseMirror');
  editable.setAttribute('aria-label', '正文：实时预览编辑器');
  editable.setAttribute('role', 'textbox'); editable.setAttribute('aria-multiline', 'true');
  applyAppearance(config);
  post({type:'ready', epoch});
}

let appliedAppearance = '';
function applyAppearance(config) {
  // Native character-count updates also send the current Markdown. Appearance
  // changes alone may touch layout; typing must not repeatedly reset it.
  const appearance = JSON.stringify([config.showTitle, config.title, config.fontSize,
    config.ink, config.alignment, config.night, config.concealed,
    config.fading, config.fadeOpacity, config.fadeDuration]);
  if (appearance === appliedAppearance) return;
  appliedAppearance = appearance;
  const title = document.querySelector('#document-title');
  title.hidden = !config.showTitle;
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
      applyAppearance(config);
      if (config.epoch !== epoch) {
        updating = true;
        epoch = config.epoch; lastNativeSource = config.markdown; lastSent = config.markdown; edited = false;
        window.ashParseSource = config.markdown;
        editor.editor.action(replaceAll(config.markdown, true));
        updating = false;
      }
    } catch (error) { post({type:'error', message:String(error.stack || error)}); }
  },
  flush,
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
