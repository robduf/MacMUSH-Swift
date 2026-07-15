// A fake MUD server for testing MacMUSH.
// Speaks real telnet: TTYPE/NAWS negotiation, ECHO suppression, GA prompts,
// GMCP, and mid-stream MCCP2 compression. Also usable standalone:
//   node test/fake-mud.js [port]

'use strict';

const net = require('net');
const zlib = require('zlib');

const IAC = 255, DONT = 254, DO = 253, WONT = 252, WILL = 251, SB = 250, GA = 249, SE = 240;
const OPT_ECHO = 1, OPT_TTYPE = 24, OPT_NAWS = 31, OPT_MCCP2 = 86, OPT_GMCP = 201;

const ESC = '\x1b';
const C = (n) => `${ESC}[${n}m`;
const RESET = C(0);

function banner() {
  return [
    '',
    `${C(1)}${C(33)}  ┌─────────────────────────────────────┐${RESET}`,
    `${C(1)}${C(33)}  │${RESET}   ${C(1)}${C(36)}Welcome to FakeMUD${RESET}                  ${C(1)}${C(33)}│${RESET}`,
    `${C(1)}${C(33)}  │${RESET}   ${C(32)}A tiny test dungeon${RESET}                 ${C(1)}${C(33)}│${RESET}`,
    `${C(1)}${C(33)}  └─────────────────────────────────────┘${RESET}`,
    '',
    `${C(31)}red ${C(32)}green ${C(33)}yellow ${C(34)}blue ${C(35)}magenta ${C(36)}cyan${RESET} ${C(1)}${C(31)}BRIGHT-RED${RESET}`,
    `${ESC}[38;5;208m256-color orange${RESET} ${ESC}[38;2;255;105;180mtruecolor hotpink${RESET} ${ESC}[4munderline${RESET} ${ESC}[3mitalic${RESET}`,
    '',
  ].join('\r\n');
}

const ROOM = [
  `${C(1)}${C(36)}The Stone Plaza${RESET}`,
  `A broad plaza of worn flagstones. A ${C(33)}brass lantern${RESET} hangs from a post.`,
  `Exits: ${C(32)}north east west${RESET}`,
].join('\r\n');

function createServer(opts = {}) {
  const sessions = new Set();
  const server = net.createServer((socket) => {
    const sess = {
      socket,
      compressed: false,
      deflater: null,
      named: false,
      echoSuppressed: false,
      lineBuf: '',
    };
    sessions.add(sess);
    socket.on('close', () => sessions.delete(sess));
    socket.on('error', () => sessions.delete(sess));

    const rawWrite = (buf) => {
      if (sess.compressed) sess.deflater.write(buf);
      else socket.write(buf);
    };
    sess.write = (s) => rawWrite(Buffer.from(s, 'utf8'));
    sess.writeBytes = (...bytes) => rawWrite(Buffer.from(bytes));
    sess.prompt = (text) => {
      sess.write(`${C(1)}${C(32)}${text}${RESET} `);
      sess.writeBytes(IAC, GA);
    };

    // Initial negotiation
    sess.writeBytes(IAC, DO, OPT_TTYPE);
    sess.writeBytes(IAC, DO, OPT_NAWS);
    if (opts.gmcp !== false) sess.writeBytes(IAC, WILL, OPT_GMCP);
    if (opts.mccp) sess.writeBytes(IAC, WILL, OPT_MCCP2);

    sess.write(banner());
    sess.prompt('What is your name?');

    let state = 0; // telnet parse state
    let sbBuf = [];
    let sbOpt = 0;
    let verb = 0;

    socket.on('data', (data) => {
      for (const b of data) {
        switch (state) {
          case 0:
            if (b === IAC) state = 1;
            else handleByte(b);
            break;
          case 1:
            if (b === IAC) { handleByte(IAC); state = 0; }
            else if (b === WILL || b === WONT || b === DO || b === DONT) { verb = b; state = 2; }
            else if (b === SB) { state = 3; }
            else state = 0;
            break;
          case 2:
            handleNegotiate(verb, b);
            state = 0;
            break;
          case 3:
            sbOpt = b; sbBuf = []; state = 4;
            break;
          case 4:
            if (b === IAC) state = 5;
            else sbBuf.push(b);
            break;
          case 5:
            if (b === IAC) { sbBuf.push(IAC); state = 4; }
            else { // SE (or anything) ends it
              handleSB(sbOpt, Buffer.from(sbBuf));
              state = 0;
            }
            break;
        }
      }
    });

    function handleNegotiate(v, opt) {
      if (v === DO && opt === OPT_MCCP2 && opts.mccp && !sess.compressed) {
        // Client accepted compression: IAC SB 86 IAC SE, then deflate everything.
        socket.write(Buffer.from([IAC, SB, OPT_MCCP2, IAC, SE]));
        sess.deflater = zlib.createDeflate({ flush: zlib.constants.Z_SYNC_FLUSH });
        sess.deflater.pipe(socket);
        sess.compressed = true;
        sess.write(`${C(35)}[compression enabled]${RESET}\r\n`);
        sess.prompt('>');
      } else if (v === DO && opt === OPT_GMCP) {
        // client will accept GMCP messages; nothing to do
      } else if (v === WILL && opt === OPT_TTYPE) {
        // ask for terminal type
        socket.write(Buffer.from([IAC, SB, OPT_TTYPE, 1, IAC, SE]));
      }
    }

    function handleSB(opt, data) {
      if (opt === OPT_TTYPE && data[0] === 0) {
        sess.ttype = data.subarray(1).toString('ascii');
      } else if (opt === OPT_NAWS && data.length >= 4) {
        sess.naws = { cols: (data[0] << 8) | data[1], rows: (data[2] << 8) | data[3] };
      } else if (opt === OPT_GMCP) {
        sess.lastGmcp = data.toString('utf8');
      }
    }

    function handleByte(b) {
      if (b === 13) return;
      if (b === 10) {
        const line = sess.lineBuf;
        sess.lineBuf = '';
        handleLine(line);
      } else {
        sess.lineBuf += String.fromCharCode(b);
      }
    }

    function handleLine(line) {
      const cmd = line.trim();
      if (!sess.named) {
        sess.named = true;
        sess.name = cmd || 'Stranger';
        sess.write(`\r\nWelcome, ${C(1)}${C(36)}${sess.name}${RESET}!\r\n\r\n${ROOM}\r\n`);
        sess.prompt('>');
        return;
      }
      if (sess.echoSuppressed) {
        // this was the "password"
        sess.writeBytes(IAC, WONT, OPT_ECHO);
        sess.echoSuppressed = false;
        sess.write(`\r\n${C(32)}Password accepted.${RESET}\r\n`);
        sess.prompt('>');
        return;
      }
      const [word, ...rest] = cmd.split(/\s+/);
      switch ((word || '').toLowerCase()) {
        case 'look':
          sess.write(`${ROOM}\r\n`);
          break;
        case 'score':
          sess.write(`HP: ${C(1)}${C(31)}87${RESET}/100  Mana: ${C(1)}${C(34)}42${RESET}/50  Gold: ${C(33)}1305${RESET}\r\n`);
          break;
        case 'say': {
          const msg = rest.join(' ');
          sess.write(`You say '${C(36)}${msg}${RESET}'\r\n`);
          break;
        }
        case 'goblin':
          sess.write(`A goblin arrives, snarling.\r\n`);
          break;
        case 'gift':
          sess.write(`Bob gives you 3 shiny apples.\r\n`);
          break;
        case 'password':
          sess.write('Enter your password: ');
          sess.writeBytes(IAC, WILL, OPT_ECHO);
          sess.echoSuppressed = true;
          return; // no prompt
        case 'gmcp':
          if (opts.gmcp !== false) {
            const payload = 'Char.Vitals ' + JSON.stringify({ hp: 87, maxhp: 100, mana: 42 });
            rawWrite(Buffer.concat([
              Buffer.from([IAC, SB, OPT_GMCP]),
              Buffer.from(payload, 'utf8'),
              Buffer.from([IAC, SE]),
            ]));
            sess.write(`${C(35)}[GMCP Char.Vitals sent]${RESET}\r\n`);
          }
          break;
        case 'wide': {
          const cols = [];
          for (let i = 0; i < 12; i++) cols.push(`${ESC}[38;5;${196 + i}m█▓▒░${RESET}`);
          sess.write(cols.join('') + '\r\n');
          break;
        }
        case 'spam':
          for (let i = 1; i <= 25; i++) sess.write(`${C(90)}[${i.toString().padStart(2)}]${RESET} The caravan rolls ever onward through line ${i}.\r\n`);
          break;
        case 'quit':
          sess.write('Farewell!\r\n');
          if (sess.compressed) sess.deflater.end(() => socket.end());
          else socket.end();
          return;
        case '':
          break;
        default:
          sess.write(`You ${cmd}.\r\n`);
      }
      sess.prompt('>');
    }
  });

  server.sessions = sessions;
  return server;
}

module.exports = { createServer };

if (require.main === module) {
  const port = parseInt(process.argv[2], 10) || 4000;
  const mccp = process.argv.includes('--mccp');
  const server = createServer({ mccp });
  server.listen(port, '127.0.0.1', () => {
    console.log(`FakeMUD listening on 127.0.0.1:${port}${mccp ? ' (MCCP2 enabled)' : ''}`);
  });
}
