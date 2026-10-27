/* Adapted from micromark-extension-gfm-strikethrough 2.1.0: use exactly two equals signs.
(The MIT License)

Copyright (c) 2020 Titus Wormer <tituswormer@gmail.com>

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
'Software'), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

*/


import { splice } from 'micromark-util-chunked';
import { classifyCharacter } from 'micromark-util-classify-character';
import { resolveAll } from 'micromark-util-resolve-all';

export function gfmHighlight(options) {
  const options_ = options || {};
  let single = false;
  const tokenizer = {
    name: 'ashHighlight',
    tokenize: tokenizeHighlight,
    resolveAll: resolveAllHighlight
  };
  if (single === null || single === undefined) {
    single = true;
  }
  return {
    text: {
      [61]: tokenizer
    },
    insideSpan: {
      null: [tokenizer]
    },
    attentionMarkers: {
      null: [61]
    }
  };

  
  function resolveAllHighlight(events, context) {
    let index = -1;

    // Walk through all events.
    while (++index < events.length) {
      // Find a token that can close.
      if (events[index][0] === 'enter' && events[index][1].type === 'ashHighlightSequenceTemporary' && events[index][1]._close) {
        let open = index;

        // Now walk back to find an opener.
        while (open--) {
          // Find a token that can open the closer.
          if (events[open][0] === 'exit' && events[open][1].type === 'ashHighlightSequenceTemporary' && events[open][1]._open &&
          // If the sizes are the same:
          events[index][1].end.offset - events[index][1].start.offset === events[open][1].end.offset - events[open][1].start.offset) {
            events[index][1].type = 'ashHighlightSequence';
            events[open][1].type = 'ashHighlightSequence';

            
            const ashHighlight = {
              type: 'ashHighlight',
              start: Object.assign({}, events[open][1].start),
              end: Object.assign({}, events[index][1].end)
            };

            
            const text = {
              type: 'ashHighlightText',
              start: Object.assign({}, events[open][1].end),
              end: Object.assign({}, events[index][1].start)
            };

            // Opening.
            
            const nextEvents = [['enter', ashHighlight, context], ['enter', events[open][1], context], ['exit', events[open][1], context], ['enter', text, context]];
            const insideSpan = context.parser.constructs.insideSpan.null;
            if (insideSpan) {
              // Between.
              splice(nextEvents, nextEvents.length, 0, resolveAll(insideSpan, events.slice(open + 1, index), context));
            }

            // Closing.
            splice(nextEvents, nextEvents.length, 0, [['exit', text, context], ['enter', events[index][1], context], ['exit', events[index][1], context], ['exit', ashHighlight, context]]);
            splice(events, open - 1, index - open + 3, nextEvents);
            index = open + nextEvents.length - 2;
            break;
          }
        }
      }
    }
    index = -1;
    while (++index < events.length) {
      if (events[index][1].type === 'ashHighlightSequenceTemporary') {
        events[index][1].type = "data";
      }
    }
    return events;
  }

  
  function tokenizeHighlight(effects, ok, nok) {
    const previous = this.previous;
    const events = this.events;
    let size = 0;
    return start;

    
    function start(code) {
      if (previous === 61 && events[events.length - 1][1].type !== "characterEscape") {
        return nok(code);
      }
      effects.enter('ashHighlightSequenceTemporary');
      return more(code);
    }

    
    function more(code) {
      const before = classifyCharacter(previous);
      if (code === 61) {
        // If this is the third marker, exit.
        if (size > 1) return nok(code);
        effects.consume(code);
        size++;
        return more;
      }
      if (size < 2 && !single) return nok(code);
      const token = effects.exit('ashHighlightSequenceTemporary');
      const after = classifyCharacter(code);
      token._open = !after || after === 2 && Boolean(before);
      token._close = !before || before === 2 && Boolean(after);
      return ok(code);
    }
  }
}