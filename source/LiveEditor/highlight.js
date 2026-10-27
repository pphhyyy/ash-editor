// Obsidian's ==emoji text== syntax, parsed by the same delimiter machinery as
// GFM strikethrough. Code, escaped delimiters and nested inline marks remain AST nodes.
import { InitReady, remarkPluginsCtx } from '@milkdown/kit/core';
import { $markSchema, $inputRule } from '@milkdown/kit/utils';
import { markRule } from '@milkdown/kit/prose';
import { gfmHighlight } from './highlight-syntax.js';

const colors = {'🔴':'red','🟠':'orange','🟡':'yellow','🟢':'green','🔵':'blue','🟣':'purple'};
function prefixOf(text) { return Object.keys(colors).find(emoji => text.startsWith(emoji)) || ''; }
function handleHighlight(node, _, state, info) {
  const tracker = state.createTracker(info), exit = state.enter('ashHighlight');
  let value = tracker.move('==' + (node.prefix || ''));
  value += state.containerPhrasing(node, {...tracker.current(),before:value,after:'='});
  value += tracker.move('=='); exit(); return value;
}
handleHighlight.peek = () => '=';

export const highlightSyntax = ctx => async () => {
  await ctx.wait(InitReady);
  const plugin = {plugin: function () {
    const data = this.data();
    (data.micromarkExtensions ||= []).push(gfmHighlight());
    (data.fromMarkdownExtensions ||= []).push({
      canContainEols:['ashHighlight'],
      enter:{ashHighlight(token) { this.enter({type:'ashHighlight',children:[]}, token); }},
      exit:{ashHighlight(token) { this.exit(token); }},
    });
    (data.toMarkdownExtensions ||= []).push({
      handlers:{ashHighlight:handleHighlight},
      unsafe:[{character:'=',inConstruct:'phrasing',notInConstruct:['autolink','destinationLiteral','destinationRaw','reference','titleQuote','titleApostrophe']}],
    });
  },options:{}};
  ctx.update(remarkPluginsCtx, plugins => [...plugins,plugin]);
  return () => ctx.update(remarkPluginsCtx, plugins => plugins.filter(item => item !== plugin));
};
export const highlightMark = $markSchema('ash_highlight', () => ({
  attrs:{prefix:{default:''}},
  inclusive:false,
  parseDOM:[{tag:'mark[data-ash-highlight]',getAttrs:dom=>({prefix:dom.getAttribute('data-ash-prefix') || ''})}],
  toDOM:mark=>['mark',{'data-ash-highlight':colors[mark.attrs.prefix] || 'yellow','data-ash-prefix':mark.attrs.prefix},0],
  parseMarkdown:{match:node=>node.type==='ashHighlight',runner:(state,node,type)=>{
    const children = node.children.map(child=>({...child}));
    const prefix = children[0]?.type==='text' ? prefixOf(children[0].value) : '';
    if (prefix) children[0].value = children[0].value.slice(prefix.length);
    state.openMark(type,{prefix}); state.next(children); state.closeMark(type);
  }},
  toMarkdown:{match:mark=>mark.type.name==='ash_highlight',runner:(state,mark)=>{ state.withMark(mark,'ashHighlight',undefined,{prefix:mark.attrs.prefix}); }},
}));
export const highlightInput = $inputRule(ctx => markRule(
  /(?<![=\\])==(?:🔴|🟠|🟡|🟢|🔵|🟣)?([^=\n]+)==$/u,
  highlightMark.type(ctx), {getAttr:match=>({prefix:prefixOf(match[0].slice(2))})}
));
