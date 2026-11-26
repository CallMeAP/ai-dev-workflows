import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, RenderChildren, ThemeSetArgs, Timer } from 'claude-code'

import { makeColors } from './make-colors.js'

// How far the lights have chased along the wire. A write redraws the band.
const phase = atom({ plugin: 'christmas-lights', key: 'phase' } as const, 0)
// The scene's own clock. Santa moves a cell each tick; the rest of the
// scene takes a step every second tick.
const tick = atom({ plugin: 'christmas-lights', key: 'tick' } as const, 0)
// Off until /christmas turns it on, for this session only.
const isOn = atom({ plugin: 'christmas-lights', key: 'isOn' } as const, false)
// How full the context window is, 0 to 100, read after each turn.
const percent = atom({ plugin: 'christmas-lights', key: 'percent' } as const, 0)

// Slow on purpose: Santa glides a cell every 1.5 s, and snow, smoke, fire,
// baubles and the snowball take a step every 3 s.
const TICK_MS = 1_500

// Bulb colours, in the order they hang on the wire.
const BULBS = ['#d7263d', '#2e8b57', '#e3b23c', '#9fd8ef', '#c45ab3'] as const
const WIRE = '#55614f'
const GOLD = '#e3b23c'
const PINE = '#2e8b57'
const FAR_PINE = '#1f5c3a'
const ICE = '#9fd8ef'
const SNOW = '#e6eef5'
const ROOF = '#a33a3a'
const WALL = '#7a4a2a'
const DOOR = '#3a2212'
const WINDOW = '#ffd36b'
const CHIMNEY = '#8c3b2e'
const SMOKE = '#c7d0d8'
// The fire in the hearth window, one of these a step.
const FIRE = ['#ff8c1a', '#ff5a1f', '#ffb347'] as const

const DAY_MS = 86_400_000

const SNOWMAN = '\u26c4'
const GIFT = '\ud83c\udf81'
const KIDS = ['\ud83d\udc66', '\ud83d\udc67'] as const
const SNOWBALL = '\u25cf'
// Santa sits on the roof this many steps: long enough to drop two gifts.
const STOP_STEPS = 8
// The decorated tree outside the hut: as wide as its lower tier.
const DECO_CELLS = 5
// Cells from one child to the other; the snowball crosses the gap between.
const KIDS_APART = 9
// The snowball's throw, a step at a time: how far along the gap it is, or
// null while a child holds it. Out and back, two cells a step.
const THROW = [0, 2, 4, 6, null, 6, 4, 2, 0, null] as const
// The hut: a roof two cells wider than its seven-cell walls.
const HUT_CELLS = 9
// Smoke from the chimney: how far right of it the puff sits, and its glyph.
const PUFFS = [
  [1, '\u00b0'],
  [2, '\u02da'],
  [2, '\u00b0'],
  [3, '\u02da'],
] as const

// One cell of a row: its glyph and how it is drawn. A wide glyph is followed
// by a cell whose glyph is '', so a row keeps one entry per terminal cell.
type Cell = { ch: string; color?: string; bg?: string; dim?: boolean; bold?: boolean }

const BLANK: Cell = { ch: ' ' }

// Santa, his sleigh and the team. The deer glyphs face left, so he flies
// right to left with the team out in front.
const SANTA = Array.from('🦌🦌🦌🛷🎅')
// A glyph of it covers two cells, so a cell of the row is half a glyph.
const SANTA_CELLS = SANTA.length * 2
// Blank cells after he leaves before he comes round again.
const REST_CELLS = 28

// Santa's round at tick `at`: his left cell (null while he is off-screen) and
// how many ticks ago he landed on the roof (negative before he has).
const santaAt = (columns: number, stopX: number, at: number): { x: number | null; sinceLanding: number } => {
  // He flies one cell a tick: in from the right edge, then on past the left.
  const approach = columns - stopX
  const stop = STOP_STEPS * 2
  const depart = stopX + SANTA_CELLS
  const round = approach + stop + depart + REST_CELLS
  const k = at % round
  const sinceLanding = k - approach

  if (k < approach) {
    return { x: columns - k, sinceLanding }
  }
  if (sinceLanding < stop) {
    return { x: stopX, sinceLanding }
  }
  if (sinceLanding < stop + depart) {
    return { x: stopX - (sinceLanding - stop + 1), sinceLanding }
  }

  return { x: null, sinceLanding }
}

// A column's flake falls through this many rows before it starts over, so
// about one column in nine shows a flake on any row.
const SNOW_CYCLE = 9
const FLAKES = ['·', '*', '+'] as const

// One scrambled number per column, so the scene is the same shape each redraw.
const hash = (n: number): number => {
  let x = Math.imul(n ^ 0x9e3779b9, 2654435761)
  x ^= x >>> 15
  x = Math.imul(x, 2246822519)

  return (x ^ (x >>> 13)) >>> 0
}

// Whole days from today until the next 25 December, in local time.
const daysToChristmas = (nowMs: number): number => {
  const now = new Date(nowMs)
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
  const thisYear = new Date(now.getFullYear(), 11, 25).getTime()
  const next = thisYear >= today ? thisYear : new Date(now.getFullYear() + 1, 11, 25).getTime()

  return Math.round((next - today) / DAY_MS)
}

const countdown = (nowMs: number): string => {
  const days = daysToChristmas(nowMs)

  if (days === 0) {
    return 'Merry Christmas!'
  }
  if (days === 1) {
    return 'Christmas is tomorrow'
  }

  return `${days} days to Christmas`
}

// One row of falling snow: a flake where a column's own cycle has reached `row`.
const snowRow = (columns: number, row: number, at: number): string[] => {
  const cells: string[] = []

  for (let x = 0; x < columns; x += 1) {
    // Its own hash, not a slice of the flake's: those bits cluster, and the
    // snow then came down in gusts with empty steps between them.
    const fallen = (at + hash(x * 131 + 17)) % SNOW_CYCLE

    cells.push(fallen === row ? (FLAKES[(hash(x) >>> 4) % FLAKES.length] as string) : ' ')
  }

  return cells
}

// The desktop and mobile apps' half: a Christmas night. The terminal draws
// none of it; there the band above the prompt is the whole scene.
const { theme: NIGHT_COLORS } = makeColors({
  label: 'Christmas night',
  only: 'dark',
  roles: { accent: '#d4a72c', danger: '#d23f4a', success: '#3f9a5f', warning: '#e08a3a', pro: '#9a76d6' },
  dark: {
    gray: {
      anchors: {
        'surface-0': '#121831',
        'surface-1': '#171e3a',
        'surface-2': '#1c2443',
        'surface-3': '#1e2646',
        'text-primary': '#eef2fb',
        'text-secondary': '#c9d1e6',
        'text-muted': '#a5afcb',
      },
    },
  },
})

const NIGHT: ThemeSetArgs = {
  colors: NIGHT_COLORS,
  // Panels frosted in the night's own blue, so the words stay easy to read.
  backdrop: { scene: 'christmas-night', glass: { blur: 14, tint: '#121831', opacity: 0.72 } },
}

// A small seeded random, so the stars and flakes sit in the same places each draw.
const seeded = (seed: number) => {
  let a = seed >>> 0

  return (): number => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = Math.imul(a ^ (a >>> 15), 1 | a)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t

    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

const n1 = (value: number): string => (Math.round(value * 10) / 10).toString()

// One layer of falling snow, drawn twice, a screen apart, so it loops seamlessly.
const flakeLayer = (name: string, count: number, radius: number, opacity: number, seed: number): string => {
  const random = seeded(seed)
  let dots = ''

  for (let i = 0; i < count; i += 1) {
    const x = n1(random() * 1600)
    const y = random() * 900

    dots += `<circle cx="${x}" cy="${n1(y)}" r="${radius}"/><circle cx="${x}" cy="${n1(y - 900)}" r="${radius}"/>`
  }

  return `<g class="${name}" fill="#ffffff" opacity="${opacity}">${dots}</g>`
}

// The backdrop: a winter night with a decorated tree, a snowman and presents on
// the left, a lit cabin with a smoking chimney on the right, and snow that lies
// deeper the fuller the context window is. Slow motion only, and every moving
// part has a resting place, for people who asked for reduced motion.
const nightScene = (full: number): string => {
  const random = seeded(7)
  let stars = ''

  for (let i = 0; i < 46; i += 1) {
    const twinkle = ['', ' class="t1"', ' class="t2"', ' class="t3"'][i % 4]

    stars += `<circle cx="${n1(random() * 1600)}" cy="${n1(random() * 470)}" r="${n1(0.8 + random() * 1.6)}"${twinkle}/>`
  }

  // The snow line: 830 with an empty window, rising to 640 with a full one.
  const top = 830 - Math.max(0, Math.min(100, full)) * 1.9
  let ground = `M0 ${n1(top)}`

  for (let x = 0; x < 1600; x += 200) {
    ground += ` Q${x + 100} ${n1(top - 14 + ((x / 200) % 2) * 22)} ${x + 200} ${n1(top)}`
  }
  ground += ' L1600 900 L0 900 Z'

  const lights = (points: readonly (readonly [number, number])[]) =>
    points
      .map(([x, y], i) => {
        const colour = ['#ff5a5f', '#ffd166', '#6fd3ff', '#8be38b'][i % 4]
        const twinkle = ['t1', 't2', 't3'][i % 3]

        return `<circle cx="${x}" cy="${y}" r="4.5" fill="${colour}" class="${twinkle}"/>`
      })
      .join('')

  return [
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1600 900" preserveAspectRatio="xMidYMax slice">',
    '<defs>',
    '<linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#070b1f"/><stop offset="0.55" stop-color="#141c42"/><stop offset="1" stop-color="#28316b"/></linearGradient>',
    '<radialGradient id="halo"><stop offset="0" stop-color="#fff6d8" stop-opacity="0.38"/><stop offset="1" stop-color="#fff6d8" stop-opacity="0"/></radialGradient>',
    '<radialGradient id="warm"><stop offset="0" stop-color="#ffcf66" stop-opacity="0.55"/><stop offset="1" stop-color="#ffcf66" stop-opacity="0"/></radialGradient>',
    '</defs>',
    '<style>',
    '@keyframes tw{0%,100%{opacity:1}50%{opacity:0.3}}',
    '.t1{animation:tw 6s ease-in-out infinite}',
    '.t2{animation:tw 8s ease-in-out 1.5s infinite}',
    '.t3{animation:tw 10s ease-in-out 3s infinite}',
    '@keyframes fall{from{transform:translateY(0)}to{transform:translateY(900px)}}',
    '.s1{animation:fall 60s linear infinite}',
    '.s2{animation:fall 85s linear infinite}',
    '.s3{animation:fall 120s linear infinite}',
    '@keyframes rise{0%{transform:translate(0,0);opacity:0}15%{opacity:0.7}100%{transform:translate(20px,-120px);opacity:0}}',
    '.m1{animation:rise 10s ease-out infinite}',
    '.m2{animation:rise 10s ease-out 3.3s infinite}',
    '.m3{animation:rise 10s ease-out 6.6s infinite}',
    '@keyframes glow{0%,100%{opacity:0.9}50%{opacity:0.55}}',
    '.fire{animation:glow 4s ease-in-out infinite}',
    '.pulse{animation:glow 7s ease-in-out infinite}',
    '</style>',
    '<rect width="1600" height="900" fill="url(#sky)"/>',
    `<g fill="#ffffff">${stars}</g>`,
    '<circle cx="1180" cy="150" r="130" fill="url(#halo)"/>',
    '<circle cx="1180" cy="150" r="44" fill="#f4efd8"/>',
    '<circle cx="1166" cy="140" r="8" fill="#e3dcc0"/><circle cx="1192" cy="166" r="6" fill="#e3dcc0"/>',
    '<polygon points="0,700 180,520 330,640 520,470 720,650 900,520 1080,660 1260,500 1440,640 1600,540 1600,900 0,900" fill="#1a2350"/>',
    '<polygon points="520,470 470,520 505,515 540,535 575,510" fill="#cfd8ea" opacity="0.55"/>',
    '<polygon points="1260,500 1215,545 1250,540 1285,560 1310,535" fill="#cfd8ea" opacity="0.55"/>',
    '<polygon points="0,780 240,640 460,740 700,620 960,750 1200,640 1420,730 1600,660 1600,900 0,900" fill="#222c5e"/>',
    // The decorated tree, with its star, garland lights and presents.
    '<rect x="243" y="790" width="24" height="46" fill="#5a3a22"/>',
    '<polygon points="255,470 345,610 165,610" fill="#1f6b45"/>',
    '<polygon points="255,540 375,700 135,700" fill="#1f6b45"/>',
    '<polygon points="255,620 405,800 105,800" fill="#1f6b45"/>',
    '<polygon points="255,470 345,610 255,610" fill="#185a3a"/><polygon points="255,540 375,700 255,700" fill="#185a3a"/><polygon points="255,620 405,800 255,800" fill="#185a3a"/>',
    '<path d="M170 606 Q255 620 340 606 M140 696 Q255 712 370 696 M110 796 Q255 812 400 796" stroke="#eef3fb" stroke-width="7" stroke-linecap="round" fill="none"/>',
    '<path d="M205 560 Q260 590 315 570 M175 650 Q250 690 345 655 M150 740 Q260 785 380 745" stroke="#e8b33a" stroke-width="3" fill="none"/>',
    lights([[205, 560], [240, 576], [278, 580], [315, 570], [175, 650], [215, 670], [255, 680], [300, 674], [345, 655], [150, 740], [195, 762], [240, 775], [290, 776], [335, 766], [380, 745]]),
    '<circle cx="230" cy="630" r="9" fill="#d23f4a"/><circle cx="290" cy="720" r="9" fill="#5aa9e6"/><circle cx="200" cy="715" r="9" fill="#e8b33a"/><circle cx="310" cy="625" r="8" fill="#b07ad6"/><circle cx="160" cy="785" r="9" fill="#d23f4a"/><circle cx="350" cy="790" r="9" fill="#e8b33a"/>',
    '<circle cx="255" cy="455" r="42" fill="url(#warm)" class="pulse"/>',
    '<polygon points="255,430 262,449 282,449 266,461 272,480 255,468 238,480 244,461 228,449 248,449" fill="#ffd75e"/>',
    '<rect x="150" y="800" width="42" height="34" fill="#c8323c"/><rect x="167" y="800" width="8" height="34" fill="#ffd166"/><rect x="150" y="813" width="42" height="7" fill="#ffd166"/>',
    '<rect x="318" y="806" width="36" height="28" fill="#3f78c8"/><rect x="332" y="806" width="7" height="28" fill="#eef3fb"/>',
    // The snowman, with his hat, scarf and carrot.
    '<circle cx="470" cy="800" r="36" fill="#f2f6fc"/><circle cx="470" cy="746" r="26" fill="#f2f6fc"/><circle cx="470" cy="706" r="19" fill="#f2f6fc"/>',
    '<rect x="452" y="672" width="36" height="8" fill="#1b1b24"/><rect x="458" y="650" width="24" height="24" fill="#1b1b24"/>',
    '<circle cx="463" cy="702" r="2.5" fill="#1b1b24"/><circle cx="477" cy="702" r="2.5" fill="#1b1b24"/><polygon points="470,708 492,712 470,714" fill="#f08a2c"/>',
    '<rect x="448" y="722" width="44" height="9" rx="4" fill="#c8323c"/><rect x="478" y="726" width="9" height="22" rx="3" fill="#c8323c"/>',
    '<circle cx="470" cy="742" r="3" fill="#1b1b24"/><circle cx="470" cy="756" r="3" fill="#1b1b24"/>',
    // The cabin: lit windows, a fire glowing in one, lights along the roof, a wreath.
    '<circle cx="1345" cy="720" r="150" fill="url(#warm)" opacity="0.6"/>',
    '<rect x="1420" y="600" width="26" height="125" fill="#8c3b2e"/><rect x="1414" y="592" width="38" height="12" rx="4" fill="#eef3fb"/>',
    '<circle cx="1433" cy="580" r="10" fill="#c7d0d8" opacity="0.5" class="m1"/><circle cx="1433" cy="580" r="12" fill="#c7d0d8" opacity="0.4" class="m2"/><circle cx="1433" cy="580" r="9" fill="#c7d0d8" opacity="0.45" class="m3"/>',
    '<polygon points="1345,560 1470,835 1220,835" fill="#6b3e24"/>',
    '<rect x="1325" y="625" width="40" height="46" fill="#ffcf66"/><path d="M1345 625 V671 M1325 648 H1365" stroke="#6b3e24" stroke-width="4"/>',
    '<rect x="1255" y="712" width="40" height="40" fill="#ff9a3c" class="fire"/><path d="M1275 712 V752 M1255 732 H1295" stroke="#6b3e24" stroke-width="4"/>',
    '<rect x="1395" y="712" width="40" height="40" fill="#ffcf66"/><path d="M1415 712 V752 M1395 732 H1435" stroke="#6b3e24" stroke-width="4"/>',
    '<rect x="1325" y="760" width="40" height="76" rx="4" fill="#3b2414"/><circle cx="1345" cy="784" r="11" stroke="#2f8a55" stroke-width="5" fill="none"/><circle cx="1345" cy="795" r="3.5" fill="#d23f4a"/>',
    '<polyline points="1200,848 1345,528 1490,848" stroke="#eef3fb" stroke-width="26" stroke-linejoin="round" fill="none"/>',
    lights([[1228, 790], [1250, 742], [1272, 694], [1294, 646], [1316, 598], [1345, 548], [1374, 598], [1396, 646], [1418, 694], [1440, 742], [1462, 790]]),
    // Snow on the ground, over the feet of everything, then snow in the air.
    `<path d="${ground}" fill="#e8eef8"/>`,
    `<path d="M0 ${n1(top + 26)} Q800 ${n1(top + 4)} 1600 ${n1(top + 26)}" stroke="#c9d4e8" stroke-width="3" fill="none" opacity="0.6"/>`,
    flakeLayer('s3', 40, 1.4, 0.5, 11),
    flakeLayer('s2', 26, 2.2, 0.7, 23),
    flakeLayer('s1', 14, 3.2, 0.85, 37),
    '</svg>',
  ].join('')
}

// Sets the night look, and says nothing where a surface has no use for it.
const showNight = async ($: EngineInterface): Promise<void> => {
  try {
    await $.theme.set(NIGHT)
  } catch (error) {
    $.ui.log(`christmas-lights: the desktop look was not set: ${String(error)}`)
  }
}

// Reads how full the context window is into `percent`, so the snow can follow it.
const readFill = async ($: EngineInterface): Promise<void> => {
  const full = await $.session.usage().then(
    usage => usage.context.percent ?? 0,
    () => 0,
  )

  await update($, percent, () => full)
}

// The running clock, while the scene is on. A reload drops it with the
// module, and session.start starts it again if the scene was on.
let clock: Timer | undefined

const startClock = ($: EngineInterface): void => {
  clock ??= $.clock.every(TICK_MS, () => update($, tick, n => n + 1))
}

const stopClock = (): void => {
  clock?.cancel()
  clock = undefined
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    // Registered in every session: the desktop app hosts its sessions the way
    // the SDK does, and a -p run only ever starts the clock if someone types it.
    await $.command.register({
      name: 'christmas',
      description: 'Turn the Christmas scene above the prompt on or off for this session',
      argumentHint: '[on|off]',
      immediate: true,
    })
    // Still on from before a reload: pick the clock and the look back up.
    if (await read($, isOn)) {
      startClock($)
      await showNight($)
    }

    return next(e)
  })

  // /christmas toggles the scene; /christmas on and /christmas off set it.
  on('command.run', { command: 'christmas' }, async ($, e) => {
    const wanted = e.args.trim().toLowerCase()
    const turnOn = wanted === 'on' ? true : wanted === 'off' ? false : !(await read($, isOn))

    await update($, isOn, () => turnOn)

    if (turnOn) {
      startClock($)
      await readFill($)
      await showNight($)
      $.ui.toast(`Christmas lights on \u2014 ${countdown(await $.clock.now())}`)

      return { text: 'Christmas scene on for this session. /christmas again turns it off.', isTextDisplayOnly: true }
    }

    stopClock()
    // The person asked for it off, which is the one time a theme is cleared.
    await $.theme.clear().catch(() => undefined)

    return { text: 'Christmas scene off.', isTextDisplayOnly: true }
  })

  // Every turn moves the lights one bulb along the wire.
  on('prompt.submit', async ($, e, next) => {
    await update($, phase, n => n + 1)

    return next(e)
    // Lights are decoration: a failure here must never hold up a prompt.
  }).catch(($, e, next) => next(e))

  on('turn.complete', async ($, e, next) => {
    await update($, phase, n => n + 1)

    // The window has grown by this turn: let the snow catch up.
    if (await read($, isOn)) {
      await readFill($)
    }

    return next(e)
  })

  // The desktop and mobile apps draw the night behind the conversation.
  on('ui.render', { component: 'Backdrop' }, async ($, e, next) => {
    if (e.surface !== 'desktop' && e.surface !== 'mobile') {
      return next(e)
    }
    if (e.props.plugin !== 'christmas-lights' || !(await read($, isOn))) {
      return next(e)
    }

    const { Svg } = $.ui.resolve(e)

    return (
      <Svg
        source={nightScene(await read($, percent))}
        alt="A snowy Christmas night: a decorated tree and a snowman on the left, a lit cabin on the right, snow falling"
        isInteractive
      />
    )
  })

  // The scene, hung in the band above the prompt: garland, snow, Santa on his
  // round, the hut he delivers to, a snowman, two children at a snowball
  // fight, the trees, and snow on the ground.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.surface !== 'terminal' || !(await read($, isOn)) || e.props.hasSurvey || e.props.maxRows < 1) {
      return next(e)
    }

    const { Box, Text } = $.ui.resolve(e)
    const offset = await read($, phase)
    const at = await read($, tick)
    // The scene's step: every second tick, so all but Santa keep a 3 s pace.
    const step = Math.floor(at / 2)
    const columns = Math.min(e.props.bodyColumns, 160)
    const rows = e.props.maxRows

    // Too narrow for the scene: leave the band alone rather than overflow it.
    if (columns < 24) {
      return next(e)
    }

    // Neighbouring cells of one style become one Text, so a row stays small.
    const draw = (key: string, cells: Cell[]) => {
      const runs: RenderChildren[] = []
      let i = 0

      while (i < cells.length) {
        const first = cells[i] as Cell
        let text = ''

        while (i < cells.length) {
          const cell = cells[i] as Cell
          const isSame =
            cell.color === first.color &&
            cell.bg === first.bg &&
            cell.dim === first.dim &&
            cell.bold === first.bold

          if (!isSame) {
            break
          }
          text += cell.ch
          i += 1
        }

        runs.push(
          <Text
            color={first.color}
            backgroundColor={first.bg}
            dimColor={first.dim}
            weight={first.bold ? 'bold' : undefined}
          >
            {text}
          </Text>,
        )
      }

      return (
        <Box key={key} flexDirection="row">
          {runs}
        </Box>
      )
    }

    // A two-cell glyph, drawn only where both of its cells exist.
    const putWide = (row: Cell[], col: number, ch: string) => {
      if (col >= 0 && col + 1 < row.length) {
        row[col] = { ch }
        row[col + 1] = { ch: '' }
      }
    }

    // Where everything stands. The hut sits right of centre with room beside
    // it for two gifts; the snowman just left of it; the children further left.
    const hutX = Math.min(Math.floor(columns * 0.62), columns - HUT_CELLS - 5)
    const snowmanX = hutX - 4
    const giftsX = [hutX + HUT_CELLS, hutX + HUT_CELLS + 2]
    // The hut needs the roof row; Santa needs the sky above it.
    const hasHut = rows >= 3
    const hasSanta = rows >= 4
    // The decorated tree stands outside, left of the snowman, when it fits.
    const decoX = snowmanX - DECO_CELLS - 2
    const hasDeco = hasHut && decoX >= 1
    const kidsX = [Math.max(3, Math.floor(columns * 0.1)), 0]
    kidsX[1] = (kidsX[0] as number) + KIDS_APART
    const hasKids = (kidsX[1] as number) + 2 < (hasDeco ? decoX : snowmanX) - 2
    // The tree's baubles take the next light colour each step.
    const bauble = (n: number) => BULBS[(step + n) % BULBS.length]

    const santa = santaAt(columns, hutX - 1, at)
    // Each gift: falling past the sky row, then the roof row, then lying in
    // the snow beside the hut until Santa comes round again.
    const giftRow = (n: number): 'sky' | 'roof' | 'ground' | null => {
      const since = Math.floor(santa.sinceLanding / 2) - 2 - n * 2

      if (!hasSanta || since < 0) {
        return null
      }

      return since === 0 ? 'sky' : since === 1 ? 'roof' : 'ground'
    }

    // The snowball between the children: its cell, and whether it is up in
    // the roof row (the top of the throw) or down by the children.
    const throwAt = THROW[step % THROW.length]
    const ball =
      hasKids && throwAt !== null && throwAt !== undefined
        ? { col: (kidsX[0] as number) + 2 + throwAt, isHigh: throwAt === 2 || throwAt === 4 }
        : null

    const scene: RenderChildren[] = []

    // The garland, strung across the top of the scene.
    const garland: Cell[] = [{ ch: '\ud83c\udf84' }, { ch: '' }]
    const bulbs = Math.max(4, Math.floor((columns - 8) / 4))

    for (let i = 0; i < bulbs; i += 1) {
      const colour = BULBS[(i + offset) % BULBS.length]
      // Every third bulb rests, so the string reads as lights and not as a rule.
      const isLit = (i + offset) % 3 !== 2

      garland.push(...Array.from('\u2500\u254c\u2500', ch => ({ ch, color: WIRE, dim: true })))
      garland.push({ ch: isLit ? '\u25cf' : '\u25cb', color: colour, dim: !isLit, bold: isLit })
    }
    garland.push(...Array.from('\u2500\u254c\u2500', ch => ({ ch, color: WIRE, dim: true })))
    garland.push({ ch: '\u2744', color: ICE })
    scene.push(draw('garland', garland))

    // The sky: snow, the chimney smoking, and Santa on his round.
    if (hasSanta) {
      const sky: Cell[] = snowRow(columns, 0, step).map(ch => (ch === ' ' ? BLANK : { ch, color: ICE, dim: true }))
      const chimney = hutX + 6
      const [drift, puff] = PUFFS[step % PUFFS.length] as (typeof PUFFS)[number]

      sky[chimney] = { ch: '\u2590', color: CHIMNEY }
      if (chimney + drift < columns) {
        sky[chimney + drift] = { ch: puff, color: SMOKE, dim: true }
      }

      // The star on top of the decorated tree.
      if (hasDeco) {
        sky[decoX + 2] = { ch: '\u2605', color: GOLD, bold: true }
      }

      giftsX.forEach((col, n) => {
        if (giftRow(n) === 'sky') {
          putWide(sky, col, GIFT)
        }
      })

      // Drawn last: on the roof he sits over the chimney, as he should.
      if (santa.x !== null) {
        for (let i = 0; i < SANTA.length; i += 1) {
          putWide(sky, santa.x + i * 2, SANTA[i] as string)
        }
      }

      scene.push(draw('sky', sky))
    }

    // The roof row: more snow, the hut's roof with its lights, a gift falling
    // past the eaves, and the snowball at the top of its throw.
    if (hasHut) {
      const roof: Cell[] = snowRow(columns, 1, step).map(ch => (ch === ' ' ? BLANK : { ch, color: ICE }))

      // A red roof hung with lights that chase once a turn, like the garland.
      roof[hutX] = { ch: '\u25e2', color: ROOF }
      for (let i = 1; i < HUT_CELLS - 1; i += 1) {
        const isBulb = i % 2 === 1

        roof[hutX + i] = isBulb
          ? { ch: '\u2022', color: BULBS[(i + offset) % BULBS.length], bg: ROOF, bold: true }
          : { ch: ' ', bg: ROOF }
      }
      roof[hutX + HUT_CELLS - 1] = { ch: '\u25e3', color: ROOF }

      // The decorated tree's upper tier, with one bauble.
      if (hasDeco) {
        roof[decoX + 1] = { ch: '\u259f', color: PINE }
        roof[decoX + 2] = { ch: '\u2022', color: bauble(0), bg: PINE, bold: true }
        roof[decoX + 3] = { ch: '\u2599', color: PINE }
      }

      giftsX.forEach((col, n) => {
        if (giftRow(n) === 'roof') {
          putWide(roof, col, GIFT)
        }
      })
      if (ball !== null && ball.isHigh) {
        roof[ball.col] = { ch: SNOWBALL, color: SNOW }
      }

      scene.push(draw('roof', roof))
    }

    // The treeline, with the children, the snowman, the hut's walls and the
    // delivered gifts standing in clearings of it.
    if (rows >= 2) {
      const trees: Cell[] = Array.from({ length: columns }, () => BLANK)
      const clearings: (readonly [number, number])[] = [
        [(hasDeco ? decoX : snowmanX) - 2, hutX + HUT_CELLS + 4],
      ]

      if (hasKids) {
        clearings.push([(kidsX[0] as number) - 2, (kidsX[1] as number) + 3])
      }

      const isClearing = (col: number) => clearings.some(([from, to]) => col >= from && col <= to)
      let x = 2 + (hash(1) % 3)
      let i = 0

      while (x + 1 < columns) {
        const seed = hash(i * 7 + 3)
        // Two trees in three stand near: taller, brighter.
        const isNear = seed % 3 !== 0

        // Block glyphs the terminal draws to the cell's bottom edge, so each
        // tree stands on the snow in the row below instead of floating.
        if (!isClearing(x) && !isClearing(x + 1)) {
          const [left, right] = isNear ? ['\u259f', '\u2599'] : ['\u2597', '\u2596']
          const look = isNear ? { color: PINE } : { color: FAR_PINE, dim: true }

          trees[x] = { ch: left, ...look }
          trees[x + 1] = { ch: right, ...look }
        }
        // Seven to ten columns to the next tree: a rhythm, never a clump.
        x += 7 + ((seed >>> 3) % 4)
        i += 1
      }

      putWide(trees, snowmanX, SNOWMAN)

      // The decorated tree's lower tier: two baubles and a bead of gold tinsel.
      if (hasDeco) {
        trees[decoX] = { ch: '\u259f', color: PINE }
        trees[decoX + 1] = { ch: '\u2022', color: bauble(1), bg: PINE, bold: true }
        trees[decoX + 2] = { ch: '\u2022', color: GOLD, bg: PINE, bold: true }
        trees[decoX + 3] = { ch: '\u2022', color: bauble(3), bg: PINE, bold: true }
        trees[decoX + 4] = { ch: '\u2599', color: PINE }
      }

      if (hasKids) {
        KIDS.forEach((kid, n) => putWide(trees, kidsX[n] as number, kid))
        if (ball !== null && !ball.isHigh) {
          trees[ball.col] = { ch: SNOWBALL, color: SNOW }
        }
      }

      if (hasHut) {
        // Window, door, and the hearth window, whose fire flickers each step.
        const walls: Cell[] = [
          { ch: ' ', bg: WALL },
          { ch: '\u25a0', color: WINDOW, bg: WALL },
          { ch: ' ', bg: WALL },
          { ch: '\u25ae', color: DOOR, bg: WALL },
          { ch: ' ', bg: WALL },
          { ch: '\u25a0', color: FIRE[step % FIRE.length], bg: WALL },
          { ch: ' ', bg: WALL },
        ]

        walls.forEach((cell, k) => {
          trees[hutX + 1 + k] = cell
        })
      }

      giftsX.forEach((col, n) => {
        if (giftRow(n) === 'ground') {
          putWide(trees, col, GIFT)
        }
      })

      scene.push(draw('trees', trees))
    }

    // Snow lying under the trees, deeper the fuller the context window is.
    // Its top is flush with the top of the cell, so it always meets the trees;
    // it deepens downward, into a second row once the window is filling up.
    if (rows >= 5) {
      const full = await read($, percent)
      // Depth in sixths of two rows: 1 is a dusting, 6 fills both rows.
      const base = 1 + (Math.max(0, Math.min(100, full)) / 100) * 4.5
      const depths: number[] = []

      for (let x = 0; x < columns; x += 1) {
        const drift = Math.sin(x / 7) + Math.sin(x / 3.1 + 1.3) * 0.5

        depths.push(Math.max(1, Math.min(6, Math.round(base + drift * 0.8))))
      }

      const upper = depths.map(d => (d === 1 ? '\u2594' : d === 2 ? '\u2580' : '\u2588')).join('')
      const lower = depths.map(d => (d === 4 ? '\u2594' : d === 5 ? '\u2580' : d === 6 ? '\u2588' : ' ')).join('')

      scene.push(<Text color={SNOW}>{upper}</Text>)
      if (rows >= 6 && lower.trim() !== '') {
        scene.push(<Text color={SNOW}>{lower}</Text>)
      }
    }

    return <Box flexDirection="column">{scene}</Box>
  })

  // The countdown, on its own row under whatever the status line already says.
  on('ui.render', { component: 'StatusLine' }, async ($, e, next) => {
    // Every mod shares this site, so keep what the ones beneath draw.
    const beneath = await next(e)

    if (!(await read($, isOn))) {
      return beneath
    }

    if (e.props.maxRows < 1) {
      return beneath
    }

    const { Box, Text } = $.ui.resolve(e)
    const line = `🎄 ${countdown(await $.clock.now())}`

    return (
      <Box flexDirection="column">
        {beneath}
        <Text color={GOLD}>{line}</Text>
      </Box>
    )
  })
}
