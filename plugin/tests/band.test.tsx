import { expect, mock, test } from 'claude-code/testing'
import type { On, SessionUsage } from 'claude-code'

const START = Date.parse('2026-10-11T12:00:00Z')
const MINUTE = 60_000

const BAND = {
  component: 'AbovePrompt',
  props: {
    hasSurvey: false,
    isWorking: false,
    maxRows: 4,
    bodyColumns: 120,
    scroll: { offset: 0, bodyRows: 4 },
    view: {},
  },
} as const

const SURFACES = ['desktop', 'vscode', 'mobile'] as const

const usage = (over: Partial<SessionUsage> = {}): SessionUsage => ({
  startedAt: START,
  context: { tokens: 68_600, window: 1_000_000, percent: 7 },
  rateLimits: [
    { kind: 'five_hour', percentUsed: 2.3, resetsAt: new Date(START + 276 * MINUTE).toISOString() },
    { kind: 'seven_day', percentUsed: 76.4, resetsAt: new Date(START + 836 * MINUTE).toISOString() },
  ],
  cost: { usd: 206.512 },
  ...over,
})

type Written = { path: string; text: string }

// The test's hooks stand for the engine beneath the mod.
const answerUsage = (
  on: On,
  figures: SessionUsage,
  host: { surface?: 'desktop' | 'terminal'; written?: Written[] } = {},
) => {
  mock.env(on, { HOME: '/Users/t' })
  on('session.usage', () => ({ value: figures }))
  on('session.id', () => ({ value: 's1' }))
  on('session.root', () => ({ value: '/Users/t/project' }))
  on('session.surface', () => ({ value: host.surface ?? 'desktop' }))
  on('fs.write', (_, e) => {
    host.written?.push({ path: e.path, text: e.text })

    return { value: undefined }
  })
  on('turn.start', (_, e) => ({ turnId: e.turnId }))
  on('session.measure', (_, e) => ({ changed: e.changed }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('turn.complete', (_, e) => ({ text: e.answer }))
}

const START_INPUT = { cwd: '/tmp', surface: 'desktop', isInteractive: true } as const

const turn = (
  over: Partial<{ read: number; written: number; input: number; output: number; agentId: string }> = {},
) => ({
  answer: 'done',
  durationMs: 1000,
  isAborted: false,
  turnId: 't1',
  reason: 'answer' as const,
  ...(over.agentId === undefined ? {} : { agentId: over.agentId }),
  usage: {
    model: 'claude-opus-5-5',
    input_tokens: over.input ?? 100,
    output_tokens: over.output ?? 9_600,
    cache_read_input_tokens: over.read ?? 9_400,
    cache_creation_input_tokens: over.written ?? 500,
  },
})

test('draws every segment on each surface', async ($, on) => {
  const clock = mock.clock(on, { now: START })
  answerUsage(on, usage())
  await $.session.start(START_INPUT)
  await $.turn.complete(turn())
  // The band's clock moves on a 5s tick, so land on one.
  await clock.advance(12 * MINUTE + 25_000)

  for (const surface of SURFACES) {
    const ui = await $.ui.mount({ plugin: 'cachecue', surface, ...BAND })
    const line = (await ui.findAll({ type: 'Text' })).map(found => found.text).join('')
    expect(line).toBe(
      'cache 94% avg 94% ◷47:35 | 5h ▰▱▱▱▱▱▱▱ 2% ↻4h23m | 7d ▰▰▰▰▰▰▱▱ 76% ↻13h43m | ↑68.6k ↓9.6k ◆1.0M | $206.51',
    )
    await ui.unmount()
  }
})

test('a fresh session shows placeholders, not zeros that look like data', async ($, on) => {
  mock.clock(on, { now: START })
  answerUsage(on, usage({ context: { window: 200_000 }, rateLimits: [], cost: undefined }))
  await $.session.start(START_INPUT)

  for (const surface of SURFACES) {
    const ui = await $.ui.mount({ plugin: 'cachecue', surface, ...BAND })
    const line = (await ui.findAll({ type: 'Text' })).map(found => found.text).join('')
    expect(line).toBe('cache -- ◷--:-- | 5h -- | 7d -- | ↑0 ↓0 ◆200.0k | $0.00')
    await ui.unmount()
  }
})

test('averages over turns, ignores subagents, and counts expiry from the last write', async ($, on) => {
  const clock = mock.clock(on, { now: START })
  answerUsage(on, usage())
  await $.session.start(START_INPUT)

  // Turn 1 writes the cache and reads nothing: 0% hit.
  await $.turn.complete(turn({ read: 0, written: 900, input: 100 }))
  await clock.advance(50 * MINUTE)
  // A subagent's turn must not move the main conversation's figures.
  await $.turn.complete(turn({ read: 0, written: 50_000, input: 0, agentId: 'a1' }))
  // Turn 2 only reads: 100% this turn, 3000/4000 overall, and no new write.
  await $.turn.complete(turn({ read: 3_000, written: 0, input: 0 }))
  await clock.advance(5 * MINUTE)

  const ui = await $.ui.mount({ plugin: 'cachecue', surface: 'desktop', ...BAND })
  const line = (await ui.findAll({ type: 'Text' })).map(found => found.text).join('')
  expect(line).toStartWith('cache 100% avg 75% ◷05:00 |')
  await ui.unmount()

  await clock.advance(6 * MINUTE)
  const later = await $.ui.mount({ plugin: 'cachecue', surface: 'desktop', ...BAND })
  expect((await later.find({ type: 'Text', text: /◷/ }))?.text).toBe('◷expired')
  await later.unmount()
})

test('a running turn shows the cache as active; the band yields to a survey and to the terminal', async ($, on) => {
  mock.clock(on, { now: START })
  // With a survey up, the mod passes to whatever is beneath it.
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>the engine's own band</Text>
  })
  answerUsage(on, usage())
  await $.session.start(START_INPUT)
  await $.turn.complete(turn())

  const working = await $.ui.mount({
    plugin: 'cachecue',
    surface: 'desktop',
    component: 'AbovePrompt',
    props: { ...BAND.props, isWorking: true },
  })
  expect((await working.find({ type: 'Text', text: /◷/ }))?.text).toBe('◷active')
  await working.unmount()

  const survey = await $.ui.mount({
    plugin: 'cachecue',
    surface: 'desktop',
    component: 'AbovePrompt',
    props: { ...BAND.props, hasSurvey: true },
  })
  expect((await survey.findAll({ type: 'Text' })).map(found => found.text)).toEqual(["the engine's own band"])
  await survey.unmount()

  // The terminal already has its status line.
  const terminal = await $.ui.mount({ plugin: 'cachecue', surface: 'terminal', ...BAND })
  expect((await terminal.findAll({ type: 'Text' })).map(found => found.text)).toEqual(["the engine's own band"])
  await terminal.unmount()
})

test('session.measure replaces the figures', async ($, on) => {
  mock.clock(on, { now: START })
  answerUsage(on, usage())
  await $.session.start(START_INPUT)
  const next = usage({
    context: { tokens: 181_000, window: 200_000, percent: 91 },
    rateLimits: [{ kind: 'five_hour', percentUsed: 95, resetsAt: new Date(START + 25 * MINUTE).toISOString() }],
    cost: { usd: 3.5 },
  })
  await $.session.measure({
    context: next.context,
    rateLimits: next.rateLimits,
    cost: next.cost,
    changed: ['context', 'rateLimits', 'cost'],
  })

  const ui = await $.ui.mount({ plugin: 'cachecue', surface: 'desktop', ...BAND })
  const line = (await ui.findAll({ type: 'Text' })).map(found => found.text).join('')
  expect(line).toContain('5h ▰▰▰▰▰▰▰▰ 95% ↻25m | 7d -- | ↑181.0k')
  // 91% of the window is close enough to auto-compact to say so.
  expect(line).toEndWith('$3.50 | ⇲ compact now')
  expect((await ui.find({ type: 'Text', text: /95%/ }))?.props.color).toBe('error')
  await ui.unmount()
})

test('leaves a snapshot for the menu bar, marked active while a turn runs', async ($, on) => {
  const clock = mock.clock(on, { now: START })
  const written: Written[] = []
  answerUsage(on, usage(), { written })
  await $.session.start(START_INPUT)
  // Loading is not activity: nothing is written until the session does something.
  expect(written).toHaveLength(0)

  await $.turn.start({ text: 'go', turnId: 't1' })
  expect(JSON.parse(written.at(-1)?.text ?? '{}')).toMatchObject({
    cache: { active: true },
    // The reading the mod found as it loaded is of unknown age.
    limits_at: null,
  })

  // A reading arriving mid-turn is fresh, and the turn is still running.
  await clock.advance(MINUTE)
  const fresh = usage()
  await $.session.measure({
    context: fresh.context,
    rateLimits: fresh.rateLimits,
    cost: fresh.cost,
    changed: ['rateLimits'],
  })
  expect(JSON.parse(written.at(-1)?.text ?? '{}')).toMatchObject({
    cache: { active: true },
    limits_at: (START + MINUTE) / 1000,
  })

  await clock.advance(MINUTE)
  await $.turn.complete(turn())

  expect(written.at(-1)?.path).toBe('/Users/t/Library/Caches/CacheCue/s1.json')
  expect(JSON.parse(written.at(-1)?.text ?? '{}')).toEqual({
    v: 1,
    source: 'desktop',
    session_id: 's1',
    cwd: '/Users/t/project',
    cache: {
      turn_hit: 94,
      avg_hit: 94,
      expires_at: (START + 62 * MINUTE) / 1000,
      active: false,
    },
    limits: {
      five_hour: { used: 2.3, resets_at: (START + 276 * MINUTE) / 1000 },
      seven_day: { used: 76.4, resets_at: (START + 836 * MINUTE) / 1000 },
    },
    limits_at: (START + MINUTE) / 1000,
    context: { tokens: 68_600, output: 9_600, window: 1_000_000, percent: 7 },
    cost_usd: 206.512,
    updated_at: (START + 2 * MINUTE) / 1000,
  })
})

test('writes no snapshot in a terminal, where the status line command does', async ($, on) => {
  mock.clock(on, { now: START })
  const written: Written[] = []
  answerUsage(on, usage(), { surface: 'terminal', written })
  await $.session.start({ ...START_INPUT, surface: 'terminal' })
  await $.turn.complete(turn())

  expect(written).toHaveLength(0)
})

test('a failed snapshot write does not cost the session its figures', async ($, on) => {
  mock.clock(on, { now: START })
  mock.env(on, { HOME: '/Users/t' })
  on('session.usage', () => ({ value: usage() }))
  on('session.id', () => ({ value: 's1' }))
  on('session.root', () => ({ value: '/Users/t/project' }))
  on('session.surface', () => ({ value: 'desktop' }))
  on('fs.write', () => ({ deny: 'disk full' }))
  on('ui.log', () => ({ value: undefined }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('turn.complete', (_, e) => ({ text: e.answer }))
  await $.session.start(START_INPUT)
  await $.turn.complete(turn())

  const ui = await $.ui.mount({ plugin: 'cachecue', surface: 'desktop', ...BAND })
  expect((await ui.findAll({ type: 'Text' })).map(found => found.text).join('')).toStartWith(
    'cache 94% avg 94% ◷60:00 |',
  )
  await ui.unmount()
})

test('cues the moment to compact, by the same rules as the menu bar app', async ($, on) => {
  const clock = mock.clock(on, { now: START })
  // 207k tokens: every request re-reads a lot.
  answerUsage(on, usage({ context: { tokens: 207_000, window: 1_000_000, percent: 21 } }))
  await $.session.start(START_INPUT)
  await $.turn.complete(turn())

  const line = async (props: Omit<typeof BAND.props, 'isWorking'> & { isWorking: boolean } = BAND.props) => {
    const ui = await $.ui.mount({ plugin: 'cachecue', surface: 'desktop', component: 'AbovePrompt', props })
    const text = (await ui.findAll({ type: 'Text' })).map(found => found.text).join('')
    const cue = await ui.find({ type: 'Text', text: /⇲/ })
    await ui.unmount()

    return { text, tone: cue?.props.color }
  }

  // Warm cache, large context: plan for the next break.
  expect(await line()).toMatchObject({ text: expect.stringMatching(/\| ⇲ compact at next break$/), tone: 'warning' })
  // A turn in flight: no cue at all.
  expect((await line({ ...BAND.props, isWorking: true })).text).not.toContain('⇲')
  // Ten minutes left: now, if stepping away.
  await clock.advance(50 * MINUTE)
  expect(await line()).toMatchObject({ text: expect.stringMatching(/\| ⇲ compact now$/), tone: 'warning' })
  await clock.advance(8 * MINUTE + 5_000)
  expect((await line()).tone).toBe('error')
  // Expired: the choice is compact or clear.
  await clock.advance(2 * MINUTE)
  expect(await line()).toMatchObject({ text: expect.stringMatching(/\| ⇲ compact or clear$/), tone: 'error' })
})

test('gives no cue on a small context, and an urgent one on a nearly full window', async ($, on) => {
  const clock = mock.clock(on, { now: START })
  answerUsage(on, usage({ context: { tokens: 30_000, window: 200_000, percent: 15 } }))
  await $.session.start(START_INPUT)
  await $.turn.complete(turn())
  await clock.advance(70 * MINUTE)

  const small = await $.ui.mount({ plugin: 'cachecue', surface: 'desktop', ...BAND })
  expect((await small.findAll({ type: 'Text' })).map(found => found.text).join('')).not.toContain('⇲')
  await small.unmount()

  const next = usage({ context: { tokens: 170_000, window: 200_000, percent: 85 } })
  await $.session.measure({ context: next.context, rateLimits: next.rateLimits, cost: next.cost, changed: ['context'] })
  const full = await $.ui.mount({ plugin: 'cachecue', surface: 'desktop', ...BAND })
  expect((await full.find({ type: 'Text', text: /⇲/ }))?.text).toBe('⇲ compact now')
  await full.unmount()
})
