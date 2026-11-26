import { expect, test } from 'claude-code/testing'

const TREE = '🎄'
const SANTA = '🎅'
const DEER = '🦌'
const DOT = '·'

const BAND = {
  plugin: 'christmas-lights',
  component: 'AbovePrompt',
  props: {
    hasSurvey: false,
    isCollapsed: false,
    isWorking: false,
    maxRows: 4,
    bodyColumns: 80,
    scroll: { offset: 0, bodyRows: 4 },
    view: {},
  },
} as const

const STATUS = {
  plugin: 'christmas-lights',
  component: 'StatusLine',
  props: { text: null, isManaged: false, isWorking: false, maxRows: 2, columns: 80 },
} as const

// Midday local time, so the countdown is the same wherever this runs.
const noonOn = (year: number, month: number, day: number): number =>
  new Date(year, month - 1, day, 12).getTime()

test('the garland hangs across the top of the scene', async ($, on) => {
  // The scene is off until /christmas; this test reads it switched on.
  on('state.get', (_, e) => ({ value: { value: e.key === 'isOn' ? true : 0, version: 1 } }))

  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })

  expect(await ui.find({ type: 'Text', text: TREE })).toBeDefined()
  // Lit bulbs and resting ones, so the string reads as lights and not as a rule.
  expect(await ui.find({ type: 'Text', text: '●' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: '○' })).toBeDefined()
  await ui.unmount()
})

test('a treeline stands under the flight path', async ($, on) => {
  // The scene is off until /christmas; this test reads it switched on.
  on('state.get', (_, e) => ({ value: { value: e.key === 'isOn' ? true : 0, version: 1 } }))

  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })

  expect(await ui.find({ type: 'Text', text: /▟▙|▗▖/ })).toBeDefined()
  await ui.unmount()
})

// Cells a row takes on screen: an emoji or the snowman covers two, anything else one.
const cellsOf = (row: string): number =>
  Array.from(row).reduce((sum, glyph) => {
    const point = glyph.codePointAt(0) ?? 0

    return sum + (point >= 0x1f000 || point === 0x26c4 ? 2 : 1)
  }, 0)

// A row's whole text, read through the runs it is drawn in.
const textOf = (node: unknown): string => {
  if (typeof node === 'string') {
    return node
  }
  if (Array.isArray(node)) {
    return node.map(textOf).join('')
  }
  if (node !== null && typeof node === 'object') {
    const element = node as { children?: unknown; props?: { children?: unknown } }

    return textOf(element.children ?? element.props?.children)
  }

  return ''
}

type Mounted = { find: (query: { key: string }) => Promise<{ children: unknown[] } | undefined> }

const rowOf = async (ui: Mounted, key: string): Promise<string | undefined> => {
  const row = await ui.find({ key })

  return row === undefined ? undefined : textOf(row.children)
}

const ROOF = /\u25e2[^\u25e3]*\u25e3/
const SNOWMAN = '\u26c4'

test('Santa flies in from the right, team first, through the snow', async ($, on) => {
  let at = 0
  // The scene's clock, which the band reads for Santa's place and the snow.
  on('state.get', (_, e) => ({
    value: { value: e.key === 'isOn' ? true : e.key === 'tick' ? at : 0, version: 1 },
  }))

  const skyRow = async (step: number): Promise<string> => {
    at = step

    const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
    const row = (await rowOf(ui, 'sky')) ?? ''
    await ui.unmount()

    return row
  }

  // At the first step he is still past the right edge.
  expect(await skyRow(0)).not.toContain(DEER)

  // One cell a tick: fully in view by tick 12, and four cells on at 16.
  const first = await skyRow(12)
  const later = await skyRow(16)

  // He has moved one cell a tick to the left, and the team leads the sleigh.
  expect(first.indexOf(DEER) - later.indexOf(DEER)).toBe(4)
  expect(first.indexOf(DEER)).toBeLessThan(first.indexOf(SANTA))
  expect(first).toMatch(/[\u00b7*+]/)
})

test('every row fills the band exactly, at any step, at odd widths too', async ($, on) => {
  let at = 0
  on('state.get', (_, e) => ({
    value: { value: e.key === 'isOn' ? true : e.key === 'tick' ? at : 0, version: 1 },
  }))

  // 95 is what a 100-column terminal leaves the band; odd widths once overflowed.
  for (const columns of [95, 80, 61, 24]) {
    // Longer than any of Santa's rounds at these widths, so every stage is seen.
    for (at = 0; at < 150; at += 1) {
      const ui = await $.ui.mount({
        ...BAND,
        surface: 'terminal',
        props: { ...BAND.props, bodyColumns: columns, maxRows: 5 },
      })

      for (const key of ['sky', 'roof', 'trees']) {
        expect(cellsOf((await rowOf(ui, key)) ?? '')).toBe(columns)
      }
      await ui.unmount()
    }
  }
})

test('Santa lands on the roof, leaves two gifts by the hut, and flies on', async ($, on) => {
  let at = 0
  on('state.get', (_, e) => ({
    value: { value: e.key === 'isOn' ? true : e.key === 'tick' ? at : 0, version: 1 },
  }))

  const steps: { x: number; roofX: number; gifts: number }[] = []

  // One whole round at 80 columns, and a little more.
  for (at = 0; at < 80; at += 1) {
    const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
    const sky = (await rowOf(ui, 'sky')) ?? ''
    const roof = (await rowOf(ui, 'roof')) ?? ''
    const trees = (await rowOf(ui, 'trees')) ?? ''
    await ui.unmount()

    steps.push({
      // Each glyph before him takes as many UTF-16 units as cells, so the
      // string index is his column.
      x: sky.indexOf(DEER),
      roofX: roof.indexOf('\u25e2'),
      gifts: (trees.match(/\ud83c\udf81/g) ?? []).length,
    })
  }

  // The longest time he stays put, and where.
  let best = { x: -1, from: 0, length: 0 }
  let from = 0

  for (let i = 1; i <= steps.length; i += 1) {
    if (i === steps.length || steps[i]?.x !== steps[from]?.x) {
      const length = i - from

      if ((steps[from]?.x ?? -1) >= 0 && length > best.length) {
        best = { x: steps[from]?.x ?? -1, from, length }
      }
      from = i
    }
  }

  // He sits on the roof, team at its left eave, for the whole stop: eight
  // scene steps, sixteen ticks.
  expect(best.length).toBe(16)
  expect(best.x).toBe((steps[best.from]?.roofX ?? 0) - 1)
  // No gifts before he lands; both lie by the hut before he leaves.
  expect(steps[best.from - 1]?.gifts).toBe(0)
  expect(steps[best.from + best.length - 1]?.gifts).toBe(2)
  // Then he flies on to the left.
  expect(steps[best.from + best.length + 1]?.x).toBeLessThan(best.x)
})

test('two children throw a snowball back and forth, up over the gap', async ($, on) => {
  let at = 0
  on('state.get', (_, e) => ({
    value: { value: e.key === 'isOn' ? true : e.key === 'tick' ? at : 0, version: 1 },
  }))

  const seen: { row: string; col: number }[] = []

  // A throw out and back is ten scene steps, which is twenty ticks.
  for (at = 0; at < 20; at += 1) {
    const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
    const roof = (await rowOf(ui, 'roof')) ?? ''
    const trees = (await rowOf(ui, 'trees')) ?? ''
    await ui.unmount()

    expect(trees).toContain('\ud83d\udc66')
    expect(trees).toContain('\ud83d\udc67')
    for (const [row, text] of [['roof', roof], ['trees', trees]] as const) {
      const col = text.indexOf('\u25cf')

      if (col >= 0) {
        seen.push({ row, col })
      }
    }
  }

  // The ball rises over the middle of the gap and is low at either end.
  expect(seen.some(ball => ball.row === 'roof')).toBe(true)
  expect(seen.some(ball => ball.row === 'trees')).toBe(true)
  // It travels, and comes back.
  const cols = seen.map(ball => ball.col)
  expect(Math.max(...cols) - Math.min(...cols)).toBe(6)
  expect(cols[0]).toBe(cols[cols.length - 1])
})

test('a decorated tree stands outside, between the children and the snowman', async ($, on) => {
  // The scene is off until /christmas; this test reads it switched on.
  on('state.get', (_, e) => ({ value: { value: e.key === 'isOn' ? true : 0, version: 1 } }))

  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  const sky = (await rowOf(ui, 'sky')) ?? ''
  const roof = (await rowOf(ui, 'roof')) ?? ''
  const trees = (await rowOf(ui, 'trees')) ?? ''
  await ui.unmount()

  // Star, upper tier, lower tier, one above the other.
  const lower = trees.indexOf('\u259f\u2022\u2022\u2022\u2599')

  expect(lower).toBeGreaterThan(-1)
  expect(roof.indexOf('\u259f\u2022\u2599')).toBe(lower + 1)
  expect(sky.indexOf('\u2605')).toBe(lower + 2)
  // Right of the children, left of the snowman.
  expect(lower).toBeGreaterThan(trees.indexOf('\ud83d\udc67'))
  expect(lower).toBeLessThan(trees.indexOf(SNOWMAN))
})

test('a snowman and a hut stand among the trees, with smoke from the chimney', async ($, on) => {
  // The scene is off until /christmas; this test reads it switched on.
  on('state.get', (_, e) => ({ value: { value: e.key === 'isOn' ? true : 0, version: 1 } }))

  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  const trees = (await rowOf(ui, 'trees')) ?? ''
  const sky = (await rowOf(ui, 'sky')) ?? ''
  await ui.unmount()

  expect(trees).toContain(SNOWMAN)
  // Window, door, and the hearth window.
  expect(trees).toMatch(/\u25a0 \u25ae \u25a0/)
  // The chimney, and a puff of smoke beside it.
  expect(sky).toMatch(/\u2590 {0,2}[\u00b0\u02da]/)
})

test('the hut needs its roof row: on a two-row band only the snowman stays', async ($, on) => {
  // The scene is off until /christmas; this test reads it switched on.
  on('state.get', (_, e) => ({ value: { value: e.key === 'isOn' ? true : 0, version: 1 } }))

  const ui = await $.ui.mount({
    ...BAND,
    surface: 'terminal',
    props: { ...BAND.props, maxRows: 2 },
  })
  const trees = (await rowOf(ui, 'trees')) ?? ''
  await ui.unmount()

  expect(trees).toContain(SNOWMAN)
  expect(trees).not.toContain('\u25ae')
})

test('snow lies under the trees when there is room, the full width of the band', async ($, on) => {
  // The scene is off until /christmas; this test reads it switched on.
  on('state.get', (_, e) => ({ value: { value: e.key === 'isOn' ? true : 0, version: 1 } }))

  const ground = /^[\u2594\u2580\u2588]+$/

  const tall = await $.ui.mount({ ...BAND, surface: 'terminal', props: { ...BAND.props, maxRows: 5 } })
  const row = await tall.find({ type: 'Text', text: ground })
  await tall.unmount()

  expect(row?.text?.length).toBe(BAND.props.bodyColumns)

  // One row shorter, and the ground is the row that goes.
  const short = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await short.find({ type: 'Text', text: ground })).toBeUndefined()
  await short.unmount()
})

test('a short band keeps the garland and the trees and drops the sky', async ($, on) => {
  // The scene is off until /christmas; this test reads it switched on.
  on('state.get', (_, e) => ({ value: { value: e.key === 'isOn' ? true : 0, version: 1 } }))

  const ui = await $.ui.mount({
    ...BAND,
    surface: 'terminal',
    props: { ...BAND.props, maxRows: 2 },
  })

  expect(await ui.find({ type: 'Text', text: TREE })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /▟▙|▗▖/ })).toBeDefined()
  // No room for Santa's row at this height.
  expect(await ui.find({ type: 'Text', text: new RegExp(SANTA) })).toBeUndefined()
  await ui.unmount()
})

test('the scene yields the band to a survey', async ($, on) => {
  // The scene is off until /christmas; this test reads it switched on.
  on('state.get', (_, e) => ({ value: { value: e.key === 'isOn' ? true : 0, version: 1 } }))

  const ui = await $.ui.mount({
    ...BAND,
    surface: 'terminal',
    props: { ...BAND.props, hasSurvey: true },
  })

  expect(await ui.find({ type: 'Text', text: TREE })).toBeUndefined()
  await ui.unmount()
})

test('the status line counts the days to Christmas', async ($, on) => {
  // The scene is off until /christmas; this test reads it switched on.
  on('state.get', (_, e) => ({ value: { value: e.key === 'isOn' ? true : 0, version: 1 } }))

  on('clock.now', () => ({ value: noonOn(2026, 12, 20) }))

  const ui = await $.ui.mount({ ...STATUS, surface: 'terminal' })

  expect((await ui.find({ type: 'Text', text: /Christmas/ }))?.text).toBe(
    `${TREE} 5 days to Christmas`,
  )
  await ui.unmount()
})

test('the countdown reads the eve, the day itself, and the day after', async ($, on) => {
  // The scene is off until /christmas; this test reads it switched on.
  on('state.get', (_, e) => ({ value: { value: e.key === 'isOn' ? true : 0, version: 1 } }))

  let now = 0
  on('clock.now', () => ({ value: now }))

  const days = [
    [noonOn(2026, 12, 24), `${TREE} Christmas is tomorrow`],
    [noonOn(2026, 12, 25), `${TREE} Merry Christmas!`],
    // The day after rolls on to next year rather than going negative.
    [noonOn(2026, 12, 26), `${TREE} 364 days to Christmas`],
  ] as const

  for (const [at, expected] of days) {
    now = at

    const ui = await $.ui.mount({ ...STATUS, surface: 'terminal' })

    expect((await ui.find({ type: 'Text', text: /Christmas/ }))?.text).toBe(expected)
    await ui.unmount()
  }
})

test('the status line keeps what is drawn beneath it', async ($, on) => {
  // The scene is off until /christmas; this test reads it switched on.
  on('state.get', (_, e) => ({ value: { value: e.key === 'isOn' ? true : 0, version: 1 } }))

  on('clock.now', () => ({ value: noonOn(2026, 12, 20) }))
  // Stands for the engine's own row, which draws the status command's output.
  on('ui.render', { component: 'StatusLine' }, ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>{e.props.text}</Text>
  })

  const ui = await $.ui.mount({
    ...STATUS,
    surface: 'terminal',
    props: { ...STATUS.props, text: `main ${DOT} 2 files` },
  })

  expect((await ui.find({ type: 'Text', text: /main/ }))?.text).toBe(`main ${DOT} 2 files`)
  expect((await ui.find({ type: 'Text', text: /Christmas/ }))?.text).toBe(
    `${TREE} 5 days to Christmas`,
  )
  await ui.unmount()
})

test('off until /christmas: nothing of the scene is drawn', async $ => {
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await band.find({ type: 'Text', text: TREE })).toBeUndefined()
  await band.unmount()

  const status = await $.ui.mount({ ...STATUS, surface: 'terminal' })
  expect(await status.find({ type: 'Text', text: /Christmas/ })).toBeUndefined()
  await status.unmount()
})

test('/christmas turns the scene and the desktop look on, and again turns them off', async ($, on) => {
  const looks: string[] = []

  on('clock.now', () => ({ value: noonOn(2026, 12, 20) }))
  on('clock.every', () => ({ value: undefined }))
  on('ui.toast', () => ({ value: undefined }))
  on('ui.log', () => ({ value: undefined }))
  on('session.usage', () => ({
    value: { startedAt: 0, context: { window: 200_000, percent: 42 }, rateLimits: [] },
  }))
  on('theme.set', (_, e) => {
    looks.push(`set ${e.backdrop !== undefined && 'scene' in e.backdrop ? e.backdrop.scene : 'none'}`)

    return { value: { isDrawn: false, reason: 'a test draws no theme' } }
  })
  on('theme.clear', () => {
    looks.push('clear')

    return { value: { isDrawn: false, reason: 'a test draws no theme' } }
  })

  // The engine stamps where a run came from and how it shows; a test leaves them out.
  const christmas = (args: string) =>
    $.command.run({ command: 'christmas', args } as Parameters<typeof $.command.run>[0])

  const garland = async (): Promise<boolean> => {
    const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
    const found = await ui.find({ type: 'Text', text: TREE })
    await ui.unmount()

    return found !== undefined
  }

  expect(await garland()).toBe(false)

  const turnedOn = await christmas('')
  expect(turnedOn.text).toMatch(/on for this session/)
  expect(await garland()).toBe(true)
  expect(looks).toEqual(['set christmas-night'])

  const turnedOff = await christmas('')
  expect(turnedOff.text).toBe('Christmas scene off.')
  expect(await garland()).toBe(false)
  expect(looks).toEqual(['set christmas-night', 'clear'])

  // `on` and `off` say what they want, whatever the state.
  await christmas('on')
  await christmas('on')
  expect(await garland()).toBe(true)
  await christmas('off')
  expect(await garland()).toBe(false)
})

test('the snow lies deeper as the context window fills', async ($, on) => {
  let full = 0
  on('state.get', (_, e) => ({
    value: { value: e.key === 'isOn' ? true : e.key === 'percent' ? full : 0, version: 1 },
  }))

  const groundRows = async (): Promise<string[]> => {
    const ui = await $.ui.mount({ ...BAND, surface: 'terminal', props: { ...BAND.props, maxRows: 6 } })
    // Rows of snow alone: at least one snow glyph, so the treeline's blank runs stay out.
    const rows = await ui.findAll({ type: 'Text', text: /^[\u2594\u2580\u2588 ]*[\u2594\u2580\u2588][\u2594\u2580\u2588 ]*$/ })
    await ui.unmount()

    return rows.map(row => row.text)
  }

  full = 0
  const empty = await groundRows()
  full = 100
  const packed = await groundRows()

  // A dusting in one row at first, never a full block.
  expect(empty.length).toBe(1)
  expect(empty[0]).not.toContain('\u2588')
  // Two rows once the window is full, the top one solid snow.
  expect(packed.length).toBe(2)
  expect(packed[0]).toMatch(/^\u2588+$/)
})

const BACKDROP = {
  plugin: 'christmas-lights',
  component: 'Backdrop',
  props: { scene: 'christmas-night', plugin: 'christmas-lights', glass: false },
} as const

test('the desktop and mobile apps draw the night behind the conversation', async ($, on) => {
  let full = 0
  on('state.get', (_, e) => ({
    value: { value: e.key === 'isOn' ? true : e.key === 'percent' ? full : 0, version: 1 },
  }))

  const scene = async (surface: 'desktop' | 'mobile'): Promise<string> => {
    const ui = await $.ui.mount({ ...BACKDROP, surface })
    const svg = await ui.find({ type: 'Svg' })
    await ui.unmount()

    expect(svg).toBeDefined()

    return String(svg?.props.source ?? '')
  }

  for (const surface of ['desktop', 'mobile'] as const) {
    full = 0
    const early = await scene(surface)
    full = 100
    const late = await scene(surface)

    // Inside the engine's bound, and pure vector.
    expect(late.length).toBeLessThan(131_072)
    expect(late).not.toMatch(/&|href|<image|data:|foreignObject/)
    // The snow line rises as the window fills.
    const snowLine = (svg: string) => Number(svg.match(/<path d="M0 ([0-9.]+)/)?.[1])
    expect(snowLine(late)).toBeLessThan(snowLine(early))
  }
})

test('on the desktop the band above the prompt stays empty: the backdrop is the scene', async ($, on) => {
  on('state.get', (_, e) => ({ value: { value: e.key === 'isOn' ? true : 0, version: 1 } }))

  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' })
  expect(await ui.find({ type: 'Text', text: TREE })).toBeUndefined()
  await ui.unmount()
})
